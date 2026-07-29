# Phase 1 — Freeze Manifest

**Status: FROZEN pending human acceptance.** The contracts below are protected
by `build/check_phase1_freeze.sh`, which runs as the last step of
`build/check.sh`. Acceptance itself is a human act; see §12.

This is the normative record of what Phase 1 froze. It is not a report and not a
changelog: it is the document a future contributor is measured against when they
propose changing the public surface. The freeze gate reads this file on every
run and resolves every evidence citation in it against the working tree, so it
cannot rot quietly into an unverifiable claim.

## What "frozen" means

Freezing is a narrow claim, and the narrowness is the point:

* the Phase-1 contracts listed here are protected by an executable gate;
* changing one requires a spec amendment, not a snapshot refresh;
* internals stay replaceable — the linear route table, the request arena, the
  vendored backend and the transport boundary are all implementation and may be
  rewritten as long as the observable contract below is unchanged;
* a semantic version, a tag and a release remain human decisions and are
  explicitly NOT granted by this document.

Freezing is **not** a claim that the framework is production-ready, that the API
is stable forever, or that anything absent from this document works. §10 lists
what Phase 1 knowingly does not do.

### How evidence is cited

Every claim below cites evidence as `path/to/file::identifier`. The gate splits
each citation, checks that the file exists, and checks that the identifier
occurs in it. A renamed test or a deleted fixture therefore fails the gate
rather than silently degrading into a claim nobody can check.

---

## 1. Toolchain and base commit

| Field | Value |
|---|---|
| Odin toolchain | `dev-2026-07-nightly:819fdc7` (pinned, `odin-version.txt`) |
| Base | `origin/main` @ `3962a48` — WP10 merged (PR #20) |
| Gate command | `env -u ODIN_ROOT DRUSE_ODIN_BIN=<odin> bash build/check.sh` |
| Gate result | `PASS=10 FAIL=0 SKIP=0` |
| Frozen ledgers | 32 application + 2 test-support = 34 exported |
| Signature snapshot | `build/phase1-public-signatures.txt` (34 lines) |
| Dependency snapshot | `build/phase1-direct-dependencies.txt` (15 lines) |

The compiler is the source of truth for the surface. The snapshots are generated
by `odin doc web -collection:druse=. -short` (procedures) and `odin doc web`
(expanded type bodies), normalized only by removing the unstable
`/* file!offset */` position markers. Names, argument lists, results, genericity,
field names, enum members and enum backing types are preserved verbatim, because
those are the contract.

---

## 2. Frozen application ledger — 32 symbols

**Types (7):** `App`, `Context`, `Handler`, `Header_View`, `Method`, `Request`,
`Status`.

**Procedures (25):** `app`, `bad_request`, `bare`, `body`, `created`, `delete`,
`destroy`, `forbidden`, `get`, `internal_error`, `json`, `no_content`,
`not_found`, `ok`, `patch`, `path`, `path_int`, `post`, `put`, `query`,
`query_int`, `query_int_or`, `serve`, `text`, `unauthorized`.

## 3. Frozen test-support ledger — 2 symbols

`Recorded_Response`, `test_request`.

These are a separate ledger by `planning/public-api-guardrails.md` G-11: public,
documented and behavior-tested exactly like the application surface, but counted
apart from the frozen 32 and required to cost nothing in applications that never
call `test_request` (§9, G-11).

## 4. Frozen types — fields, backing types, members

Reproduced verbatim from the compiler; `build/check_phase1_freeze.sh` asserts
each of these as a named expectation, in addition to diffing the whole snapshot.
The named assertions are redundant on purpose: if someone regenerates the
snapshot to make a change "pass", the named assertions still fail, because they
encode the decision rather than the current state.

```
App               :: struct {private: App_Internal}
Context           :: struct {request: Request, private: Context_Internal}
Handler           :: proc(ctx: ^Context)
Header_View       :: struct {private: Header_View_Internal}
Method            :: enum u8 {UNKNOWN, GET, POST, PUT, PATCH, DELETE}
Request           :: struct {method: Method, path: string, query: string, headers: Header_View, body: []u8}
Status            :: enum int {OK = 200, Created = 201, Accepted = 202, No_Content = 204,
                               Bad_Request = 400, Unauthorized = 401, Forbidden = 403,
                               Not_Found = 404, Method_Not_Allowed = 405,
                               Internal_Server_Error = 500}
Recorded_Response :: struct {status: Status, body: string}
```

Frozen alongside the shapes:

* `Method` is backed by `u8` and has exactly six members, with `UNKNOWN` as the
  zero value. Evidence: `tests/wp2-public-surface/contract_test.odin::wp2_method_members_are_uppercase`.
* `Status` is backed by `int`, the member values ARE the HTTP codes, and there
  are exactly ten. **There is no public 413.** The 4 MiB body cap is real and
  emits 413 on the wire, but it is a private HTTP behavior of the transport and
  adding a `Status` member for it is a gate failure. Evidence:
  `build/check_public_api.sh::public 413 Status member`.
* `Handler` is the only handler shape. There is no second form, no error-returning
  variant and no context-plus-state variant. Evidence:
  `tests/wp2-public-surface/contract_test.odin::wp2_handler_signature_is_unchanged`.
* `Context` exposes `request` and nothing else. There is no public `response`,
  no `params`, no `route`, no `user_data`, no `locals`. Evidence:
  `tests/wp2-public-surface/probes/context_has_no_response.odin::web.Context`.
* `Header_View` is opaque and carries **no public lookup**. Phase 1 ships no
  `web.header` and no `web.bearer_token`. Evidence:
  `tests/wp2-public-surface/probes/header_view_internal_not_exported.odin::Header_View_Internal`.
* No exported procedure carries `#optional_ok`. Dropping `ok` from a
  value-producing extractor is a compile error (ADR-002). Evidence:
  `tests/wp5-public-surface/probes/discard_path_int_ok.odin::path_int`.
* Genericity is contract: `body` is destination-filling (`dst: ^$T -> bool`);
  `json`, `ok` and `created` take their payload **by value** (`$T`). A pointer
  payload is not part of the contract. Evidence:
  `tests/wp7-public-surface/contract_test.odin::wp7_signature_is_the_canonical_destination_filling_shape`.

---

## 5. Evidence matrix — 34 symbols

Every row was produced by reading the cited file. `Compile` proves the shape
compiles at a call site; `Behavior` proves what it does at run time; `Docs`
points at the canonical teaching material. A signature without behavior evidence
would not be frozen — all 34 have both.

Ledger key: **A** = application, **T** = test-support.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `App` | A | WP1/WP4 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp4-internal/wp4_internal_test.odin::wp4_an_app_with_no_routes_allocates_nothing` | `docs/ai-context.md::App` | owns route table + cloned patterns; by value, destroyed once |
| `Context` | A | WP2 | `tests/wp2-public-surface/contract_test.odin::wp2_context_carries_the_request` | `tests/wp2-internal/wp2_internal_test.odin::wp2_context_carries_an_uncommitted_response` | `docs/quick-start.md::Context` | holds private response + arena; no public response |
| `Handler` | A | WP2 | `tests/wp2-public-surface/contract_test.odin::wp2_handler_signature_is_unchanged` | `tests/wp4-public-surface/contract_test.odin::wp4_registered_route_is_reached_exactly_once` | `docs/ai-context.md::Handler` | plain proc value, returns nothing |
| `Header_View` | A | WP2 | `tests/wp2-public-surface/contract_test.odin::wp2_request_exposes_the_ratified_fields` | `tests/wp2-internal/wp2_internal_test.odin::wp2_header_view_wraps_pairs_without_copying` | `docs/canonical-patterns.md::Header_View` | non-owning alias; no copy, no lookup |
| `Method` | A | WP2 | `tests/wp2-public-surface/contract_test.odin::wp2_method_members_are_uppercase` | `tests/wp2-internal/wp2_internal_test.odin::wp2_unsupported_method_tokens_convert_to_unknown` | `docs/ai-context.md::Method` | value enum, no allocation |
| `Request` | A | WP2 | `tests/wp2-public-surface/contract_test.odin::wp2_request_exposes_the_ratified_fields` | `tests/wp2-internal/wp2_internal_test.odin::wp2_buffer_reuse_invalidates_retained_views` | `docs/canonical-patterns.md::lifetime` | all fields are views into transport memory |
| `Status` | A | WP6 | `tests/wp9-public-surface/contract_test.odin::wp9_public_surface_is_unchanged` | `tests/wp6-internal/wp6_internal_test.odin::wp6_json_preserves_an_arbitrary_status` | `docs/ai-context.md::Status` | value enum backed by the HTTP code |
| `app` | A | WP1/WP4 | `tests/wp9-public-surface/contract_test.odin::wp9_public_surface_is_unchanged` | `tests/wp4-public-surface/contract_test.odin::wp4_app_returns_404_for_an_unknown_path` | `examples/01-hello-world/main.odin::web.app` | returns owned App by value; installs default 404/405 |
| `bad_request` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_error_helpers_produce_the_ratified_envelopes` | `docs/errors.md::bad_request` | response owns the envelope body |
| `bare` | A | WP1/WP4 | `tests/wp9-public-surface/contract_test.odin::wp9_added_no_transport_surface` | `tests/wp4-internal/wp4_internal_test.odin::wp4_bare_injects_no_404` | `docs/errors.md::bare` | as `app`, but installs no default policy |
| `body` | A | WP7 | `tests/wp7-public-surface/contract_test.odin::wp7_signature_is_the_canonical_destination_filling_shape` | `tests/wp7-internal/wp7_internal_test.odin::wp7_decoded_data_lives_in_the_request_arena` | `docs/quick-start.md::web.body` | fills caller dst; nested data in the request arena |
| `created` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_created_is_byte_identical_to_json_created` | `examples/02-json-api/main.odin::web.created` | delegates to `json`; response owns the body |
| `delete` | A | WP4 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp4-public-surface/contract_test.odin::wp4_every_verb_registers` | `docs/canonical-patterns.md::web.delete` | App clones the pattern |
| `destroy` | A | WP3/WP4 | `tests/wp9-public-surface/contract_test.odin::wp9_public_surface_is_unchanged` | `tests/wp4-internal/wp4_internal_test.odin::wp4_destroy_releases_the_table_exactly_once` | `examples/01-hello-world/main.odin::web.destroy` | frees table, patterns, recorder; exactly once |
| `forbidden` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-public-surface/contract_test.odin::wp6_error_helpers_are_observable_end_to_end` | `docs/errors.md::forbidden` | response owns the envelope |
| `get` | A | WP4 | `tests/wp9-public-surface/contract_test.odin::wp9_public_surface_is_unchanged` | `tests/wp4-internal/wp4_internal_test.odin::wp4_static_route_matches_and_runs_handler_once` | `examples/01-hello-world/main.odin::web.get` | clones pattern into App storage |
| `internal_error` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp8-internal/wp8_internal_test.odin::wp8_uncommitted_response_is_finalized_to_500` | `docs/errors.md::internal_error` | static envelope, allocates nothing |
| `json` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_marshal_failure_leaves_no_partial_body` | `docs/canonical-patterns.md::web.json` | response OWNS the marshalled buffer |
| `no_content` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_no_content_is_empty_and_header_free` | `examples/02-json-api/main.odin::web.no_content` | allocates nothing |
| `not_found` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_not_found_escapes_the_resource_name` | `docs/errors.md::not_found` | composes and owns the envelope body |
| `ok` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_ok_is_byte_identical_to_json_ok` | `examples/03-route-params/main.odin::web.ok` | delegates to `json`; response owns the body |
| `patch` | A | WP4 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp4-internal/wp4_internal_test.odin::wp4_allow_uses_the_canonical_method_order` | `examples/02-json-api/main.odin::web.patch` | clones pattern |
| `path` | A | WP5 | `tests/wp5-public-surface/contract_test.odin::wp5_extractor_signatures_are_exact` | `tests/wp5-internal/wp5_internal_test.odin::wp5_path_value_is_a_view_over_the_request_path` | `examples/03-route-params/main.odin::web.path` | returns a VIEW; never responds |
| `path_int` | A | WP5 | `tests/wp5-public-surface/probes/discard_path_int_ok.odin::path_int` | `tests/wp5-internal/wp5_internal_test.odin::wp5_path_int_failure_commits_the_exact_envelope` | `docs/errors.md::invalid_path_parameter` | commits 400 on failure; no allocation on success |
| `post` | A | WP4 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp8-socket/socket_test.odin::wp8_real_server_serves_and_stops` | `examples/02-json-api/main.odin::web.post` | clones pattern |
| `put` | A | WP4 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp4-public-surface/contract_test.odin::wp4_methods_are_isolated_publicly` | `examples/02-json-api/main.odin::web.put` | clones pattern |
| `query` | A | WP5 | `tests/wp5-public-surface/contract_test.odin::wp5_extractor_signatures_are_exact` | `tests/wp5-internal/wp5_internal_test.odin::wp5_query_does_not_decode_anything` | `examples/03-route-params/main.odin::web.query` | returns a VIEW; no decoding; never responds |
| `query_int` | A | WP5 | `tests/wp5-public-surface/probes/discard_query_int_ok.odin::query_int` | `tests/wp5-internal/wp5_internal_test.odin::wp5_query_int_present_but_invalid_commits_the_integer_envelope` | `docs/errors.md::invalid_query_parameter` | commits 400 on failure |
| `query_int_or` | A | WP5 | `tests/wp5-public-surface/probes/discard_query_int_or_ok.odin::query_int_or` | `tests/wp5-internal/wp5_internal_test.odin::wp5_query_int_or_never_substitutes_the_default_for_a_malformed_value` | `examples/03-route-params/main.odin::web.query_int_or` | default ONLY on absence; 400 on malformed |
| `serve` | A | WP8 | `tests/wp9-public-surface/contract_test.odin::wp9_added_no_transport_surface` | `tests/wp8-socket/socket_test.odin::wp8_real_server_serves_and_stops` | `docs/quick-start.md::web.serve` | blocking; per-request arena torn down by the driver |
| `text` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-internal/wp6_internal_test.odin::wp6_text_copies_the_caller_buffer` | `examples/01-hello-world/main.odin::web.text` | COPIES the caller's string into response-owned memory |
| `unauthorized` | A | WP6 | `tests/wp1-public-api/contract_test.odin::wp1_public_api_surface_compiles` | `tests/wp6-public-surface/contract_test.odin::wp6_error_helpers_are_observable_end_to_end` | `docs/errors.md::unauthorized` | response owns the envelope |
| `Recorded_Response` | T | WP3 | `tests/wp3-public-surface/probes/recorded_response_has_no_headers.odin::Recorded_Response` | `tests/wp3-public-surface/contract_test.odin::wp3_two_recorded_responses_survive_until_destroy` | `docs/canonical-patterns.md::Recorded_Response` | `body` is an App-owned copy, valid until `destroy` |
| `test_request` | T | WP3, amended WP14 | `tests/wp7-public-surface/contract_test.odin::wp7_test_request_signature_is_pinned` | `tests/wp14-public-surface/contract_test.odin::wp14_a_json_body_reaches_the_handler` | `docs/quick-start.md::web.test_request` | lazily allocates recorder state; results owned until `destroy`; `body` is borrowed for the call only |

### Evidence asymmetries recorded honestly

These are not gaps in the freeze — every symbol above has real behavior
evidence — but the audit found four places where coverage is thinner than the
surrounding rows, and a freeze manifest that hid them would be worth less:

1. **`Header_View` has no *public* behavior evidence, by design.** There is no
   public API to exercise: the type is opaque and Phase 1 ships no lookup. Its
   behavioral assertions run from inside `package web`. The "no public lookup"
   property is proven negatively, by compile probe.
2. **`Status` is proven on the wire for 6 of its 10 members** (200, 201, 204,
   400, 404, 405, via `tests/support/transport_conformance/semantic.odin::expect_status`).
   `Accepted` (202), `Unauthorized` (401) and `Forbidden` (403) are observed only
   as enum values in in-memory tests, never as an integer on a socket.
3. **`created`'s byte-identity test is weaker than `ok`'s.** `ok` is compared to
   `json` on status, body *and* header count; `created` is compared on body and
   status only. The delegation claim is proven for the body; header parity rests
   on `tests/wp6-public-surface/contract_test.odin::wp6_created_returns_201`.
4. **`unauthorized` and `forbidden` are proven in memory only.** Neither appears
   in the WP9 semantic matrix or the wire corpus, so neither has crossed a real
   socket in the suite.

These are recorded as accepted limitations (§10), not deferred obligations. None
of them changes a frozen signature or a frozen behavior; closing them adds test
coverage, which a later phase may do without a spec amendment.

---

## 6. Frozen behavioral contracts

### App lifecycle

`app()` returns `App` **by value** and stores no pointer to the pre-return local
(ADR-001, ratified by `experiments/01-api-shape/README.md::ADR-001`). The caller
keeps that value, passes `&app` to every mutating operation, and calls `destroy`
on that same value exactly once. **App is non-copyable by contract**: a copy must
never be destroyed independently. `bare()` is `app()` without the default 404/405
policy. Routes and recorder state are released exactly once.

Evidence: `tests/wp4-internal/wp4_internal_test.odin::wp4_destroy_releases_the_table_exactly_once`,
`tests/wp4-internal/wp4_internal_test.odin::wp4_bare_injects_no_405`,
`tests/wp3-internal/wp3_internal_test.odin::wp3_destroy_releases_everything_exactly_once`.

### Routing

Observable and frozen: static routes; at most one `:param` per pattern; static
wins over param; per-method isolation; the handler runs exactly once; 404 for an
unknown path; 405 with an exact `Allow` header for a known path under another
method; an unknown method never becomes 501; **no normalization of any kind** —
`/users` and `/users/` are different paths and stay that way; route conflicts are
not diagnosed in Phase 1.

**The linear table itself is NOT frozen.** It is an interim structure and Phase 3
may replace it with a compact per-method tree, as long as everything in the
previous paragraph stays true.

Evidence: `tests/wp4-internal/wp4_internal_test.odin::wp4_static_route_matches_and_runs_handler_once`,
`tests/wp4-internal/wp4_internal_test.odin::wp4_allow_uses_the_canonical_method_order`,
`tests/wp4-public-surface/contract_test.odin::wp4_methods_are_isolated_publicly`.

### Request and lifetimes

`Request` carries `method`, `path`, `query`, `headers`, `body`. **Every string
and slice on it is a view over transport-owned storage and is valid only for the
duration of the request.** Persisting any of them requires an explicit copy. No
`Context` and no view derived from it may be handed to background work.

Evidence: `tests/wp2-internal/wp2_internal_test.odin::wp2_buffer_reuse_invalidates_retained_views`,
`tests/wp2-internal/wp2_internal_test.odin::wp2_explicit_copy_survives_buffer_reuse`,
`docs/canonical-patterns.md::copy-to-persist`.

### Extractors

`path` and `query` return views. Value-producing extractors return `(value, ok)`
and deliberately omit `#optional_ok`, so dropping `ok` is a compile error.
`query_int_or` substitutes its default **only on absence** — a malformed value is
still a 400, never the default. Malformed input always commits 400. Integer
parsing is strict decimal. Names are case-sensitive. Nothing is percent-decoded
and `+` is not a space. For a duplicated query key the first occurrence wins;
this is the minimum rule and is **not** a promise of multi-value support.

Evidence: `tests/wp5-internal/wp5_internal_test.odin::wp5_query_int_or_treats_an_empty_value_as_malformed_not_absent`,
`tests/wp5-internal/wp5_internal_test.odin::wp5_query_does_not_decode_anything`,
`tests/wp5-internal/wp5_internal_test.odin::wp5_path_int_rejects_empty_text_and_overflow`.

### Body binding

There is a **single consumer**: the first `web.body` call consumes the capability,
and a second call does not reprocess. An empty or invalid body is a 400. The
limit is a **fixed 4 MiB**, not configurable; over the limit is 413, and the cap
is checked **before** the arena is created and before the parser runs. JSON is
decoded in the toolchain's strict mode. Nested decoded data lives in the
request-local arena and is cleaned up exactly once. An internal failure logs and
becomes a 500.

Evidence: `tests/wp7-internal/wp7_internal_test.odin::wp7_one_over_the_limit_is_too_large_before_parse_and_arena`,
`tests/wp7-internal/wp7_internal_test.odin::wp7_a_successful_first_bind_consumes_the_capability`,
`tests/wp7-internal/wp7_internal_test.odin::wp7_decoded_data_is_independent_of_the_raw_buffer`.

### Response

`Response` and its `committed` flag are **private**; there is no public response
object and no `ctx.response`. **First commit wins.** JSON and text bodies are
copied or owned by the response and released by `response_destroy`, which the
driver calls *after* the response has been captured or written. A marshal failure
is recorded before the 500 and **never leaves a partial body**. Payloads are taken
by value; a pointer payload is not part of the contract. Automatic headers are
correct and a 204 carries an empty body with no content headers.

Evidence: `tests/wp6-internal/wp6_internal_test.odin::wp6_marshal_failure_leaves_no_partial_body`,
`tests/wp6-internal/wp6_internal_test.odin::wp6_response_owns_the_rendered_body`,
`tests/wp6-internal/wp6_internal_test.odin::wp6_no_content_is_empty_and_header_free`.

### Errors — the ten Phase-1 codes

`invalid_path_parameter`, `invalid_query_parameter`, `invalid_json`,
`body_too_large`, `bad_request`, `not_found`, `method_not_allowed`,
`unauthorized`, `forbidden`, `internal_error`.

The envelope is always `{"error": {"code": ..., "message": ..., "field": ...}}`
with **`field` omitted entirely** when the error is not bound to an input field
(AMEND-2); only the two extractor errors carry one. Status, ratified message,
field presence, `Content-Type` and single-commit are all frozen. Protocol errors
detected before Inbound are a separate concern and never wear this envelope.

Evidence: `tests/wp6-internal/wp6_internal_test.odin::wp6_error_helpers_produce_the_ratified_envelopes`,
`docs/errors.md::body_too_large`, `docs/errors.md::method_not_allowed`.

### Test-support

Exactly two public symbols. `Recorded_Response` carries **only** `status` and
`body`; there is no headers field. A recorded body stays valid until
`destroy(&app)`, and responses recorded earlier stay valid when later ones are
recorded. There is no public cleanup call, no socket and no port anywhere on the
path. The recorder registers **lazily**, so an application that never calls
`test_request` links zero `web/testing` symbols.

Evidence: `tests/wp3-public-surface/contract_test.odin::wp3_two_recorded_responses_survive_until_destroy`,
`tests/wp3-public-surface/contract_test.odin::wp3_unused_test_support_is_a_noop_destroy`,
`build/check_g11_teardown.sh::DRUSE_G11_PATTERN`.

### Transport

Only the **conceptual** contract is frozen: `accept → dispatch → commit → stop`.
The private ABI between `web` and `web/internal/transport` is explicitly NOT
frozen and may be redesigned.

Frozen: the backend never appears in a public signature; the body is limited
during reading, not after; the response is copied before cleanup; a handler that
commits nothing is finalized to 500; `stop` is basic and idempotent; the semantic
conformance matrix and the raw-wire corpus hold on both transports; framing is
defensive; `Expect: 100-continue` is rejected rather than auto-answered (WP9);
and no request-smuggling vector succeeds in the covered cases.

Evidence: `tests/wp9-semantic/http_factory_test.odin::wp9_semantic_matrix_on_the_real_http_transport`,
`tests/wp9-wire/wire_test.odin::wp9_raw_wire_corpus`,
`tests/wp8-internal/wp8_internal_test.odin::wp8_uncommitted_response_is_finalized_to_500`,
`docs/transport-conformance.md::100-continue`.

---

## 7. Dependency inventory

Snapshot: `build/phase1-direct-dependencies.txt` (23 direct imports, diffed on
every gate run).

| Package | Direct imports |
|---|---|
| `web` | `core:mem`, `core:strings`, `core:encoding/json`, `core:os`, `core:reflect`, `core:strconv`, `druse:web/testing`, `druse:web/internal/transport` |
| `web/testing` | `core:mem`, `core:strings` |
| `web/internal/transport` | `core:mem`, `core:net`, `core:slice`, `core:strings`, `core:time`, `druse:vendor/odin-http` |
| `examples/01..03` | `druse:web` only |

**Third-party.** Exactly one vendored dependency:

| Field | Value |
|---|---|
| Package | `laytan/odin-http` (root server package only) |
| Commit | `112c49b5bcee31308a695cc3f05d156d314a61a6` |
| License | MIT, Copyright (c) 2023 Laytan Laats (`vendor/odin-http/LICENSE`) |
| Owner | `web/internal/transport` — nothing else imports it |
| Record | `vendor/odin-http/VENDOR.md::Provenance` |

**Verified structural properties** (asserted by `build/check_phase1_freeze.sh`,
independently of the snapshot):

* no backend type appears in any exported signature;
* no example imports the vendor directly;
* `web/testing` does not import `web` — the back-edge is a compile cycle;
* `web/internal/transport` does not import `web` — the boundary is one-way;
* no package that ships inside application binaries imports `core:testing`;
* `web/testing` imports no networking package, so `test_request` reaches no socket;
* every dependency has a named owner and a license.

**Observed dynamic libraries** (`ldd`, all five cost fixtures, identical):
`linux-vdso.so.1`, `libm.so.6`, `libc.so.6`, `ld-linux-x86-64.so.2`. WP11 adds
none.

---

## 8. Ownership and lifetimes

| Data | Owner | Valid until |
|---|---|---|
| `App` value | the caller | `destroy(&app)`, exactly once, on the original value |
| Route patterns | `App` (cloned on registration) | `destroy` |
| `Request` fields | the transport | end of the request |
| `path`/`query` results | the transport (views) | end of the request |
| Decoded `body` nested data | the request arena | request teardown |
| Rendered response body | the internal `Response` | `response_destroy`, after capture/write |
| `Recorded_Response.body` | `App` (copied out) | `destroy(&app)` |

The single rule an application must remember: **anything reachable from
`ctx.request` is a view; copy it to keep it.**

---

## 9. Guardrail audit — G-01..G-11

Definitions in `planning/public-api-guardrails.md`. Ten of the eleven are backed
by executable enforcement; G-02 is not, and that is stated rather than smoothed
over.

| # | Guardrail | Result | Evidence |
|---|---|---|---|
| G-01 | One operation, one name | **PASS** | `build/check_public_api.sh::DRUSE_EXPECTED_EXPORTS` — two-way `comm` diff of the extracted inventory; no synonym pair exists. `ok`/`created` are sanctioned exact delegations, proven by `tests/wp6-internal/wp6_internal_test.odin::wp6_ok_is_byte_identical_to_json_ok` |
| G-02 | Framework types stop at the HTTP boundary | **PASS (review-enforced only)** | `docs/canonical-patterns.md::boundary`. Structurally, `body` fills a caller-owned plain struct: `tests/wp7-internal/wp7_internal_test.odin::wp7_binds_nested_strings_and_slices`. **No gate asserts that a domain package is free of `druse:web`** — see the caveat below |
| G-03 | `Context` is not an extension bag | **PASS** | `build/check_public_api.sh::user_data` bans `user_data`/`locals`/`values`, `map[string]any`, `any` and `rawptr` in exported declarations; shape locked to `request` + `private`. Probe: `tests/wp2-public-surface/probes/context_has_no_response.odin::web.Context` |
| G-04 | Response side effects singular and visible | **PASS** | `tests/wp2-internal/wp2_internal_test.odin::wp2_second_commit_is_rejected_and_changes_nothing`; `tests/wp6-public-surface/contract_test.odin::wp6_the_first_response_wins`; `tests/wp5-public-surface/contract_test.odin::wp5_continued_handler_code_cannot_replace_the_400` |
| G-05 | Request views never escape implicitly | **PASS** | `tests/wp2-internal/wp2_internal_test.odin::wp2_buffer_reuse_invalidates_retained_views` and `::wp2_explicit_copy_survives_buffer_reuse`; `tests/wp6-internal/wp6_internal_test.odin::wp6_text_copies_the_caller_buffer` |
| G-06 | Backend stays private | **PASS** | `build/check_public_api.sh::DRUSE_BACKEND_USERS` requires exactly ONE backend importer, inside `web/internal/transport/` (the adapter, derived rather than named — WP16), and bans `odin-http`/`nbio`/`laytan` in `web/` and `examples/`; `tests/wp9-public-surface/contract_test.odin::wp9_added_no_transport_surface` |
| G-07 | Optionals do not enlarge core | **PASS** | `build/check_public_api.sh::serve_with` — hard rejection loop over `use`, `router`, `group`, `mount`, `next`, `header`, `bearer_token`, `serve_with`, `recovery`, `Response`, `Transport` and more |
| G-08 | Defaults claimed only when delivered | **PASS** | `build/check_docs.sh::production.ready` — stale-claim blacklist; the 4 MiB cap is real and tested: `tests/wp7-internal/wp7_internal_test.odin::wp7_exactly_the_limit_is_not_too_large` |
| G-09 | Public growth carries evidence | **PASS** | Satisfied by §5 of this manifest plus `build/phase1-public-signatures.txt` and `build/phase1-direct-dependencies.txt`; enforced by `build/check_phase1_freeze.sh::evidence` |
| G-10 | No linter/analyzer as a product | **PASS** | Enforcement is compile probes, behavior tests and static repository assertions only — `build/check_public_api.sh::static repository assertions`. No CLI, generator or analyzer exists in the tree |
| G-11 | Test-support ledger and cost separated | **PASS** | `build/check_g11_teardown.sh::DRUSE_G11_PATTERN` with a positive control and a static-edge mutation. Executed: never-tests → **0** `web/testing` symbols; does-test → **11**; mutation → 4, correctly rejected |

**No guardrail is deferred.** Every Phase-1 obligation is met in Phase 1; the
deferrals recorded in §11 are features that do not belong to Phase 1 at all.

### G-02 caveat, recorded rather than smoothed over

G-02 is the only guardrail whose PASS rests on documentation and reviewer
discipline instead of an executable check. Nothing in the repository asserts that
an application's domain package is free of `druse:web`; all three examples are
single-file `package main` programs, so they neither demonstrate nor violate the
boundary. G-10 explicitly sanctions review as an enforcement mode, so this is not
a broken promise — but a reader cannot tell "enforced" from "unenforced" here.
**Forwarded to Phase 2: add a multi-package example plus a gate asserting the
domain package does not import `druse:web`.** This does not block the freeze:
it constrains no frozen signature and no frozen behavior.

### Risk and open-question triage

All 19 risks, 20 open questions, 14 ADRs and 11 research items were classified.
**No open blocker is assigned to Phase 1.** Highlights:

* Resolved in Phase 1 with executed evidence: R-01, R-04, R-05, R-06, R-07,
  R-08, R-09, R-10, R-12, R-14, R-15, R-17; ADR-001, -002, -006, -007, -008,
  -009, -011, -012, -014.
* Accepted limitations: R-02 (pinned beta backend, confined to one file),
  R-13/ADR-003 (value-only payloads).
* Deferred: R-03 → 5; R-16 → 3; R-18 → 3/4; R-19/ADR-013 → 4; ADR-005
  (middleware) → 2; ADR-004 (typed state) → 3; ADR-010 (Advanced API) →
  post-Phase-1. ADR-005, -010 and -013 are **PROPOSED, not accepted**, and are
  recorded as such.
* R-11 ("freeze discipline violated") named WP11 itself as its own mitigation:
  the freeze must be computed from executed runner output only. This manifest
  and the two committed snapshots are that output; R-11 closes with this
  work.

---

## 10. Accepted limitations

Shipped as-is, documented, not blocking:

* No header lookup. `Header_View` is opaque; `web.header` and `web.bearer_token`
  are Phase 2.
* No path normalization: trailing slashes, dot segments and percent-encoding are
  all significant and untouched.
* No percent-decoding or `+`-as-space in query values.
* Duplicate query keys: first wins; no multi-value access.
* Body limit fixed at 4 MiB, not configurable.
* No configurable timeouts. `stop` is basic and idempotent, not a graceful
  drain.
* Route conflicts are not diagnosed.
* One `:param` per pattern; no wildcards.
* The four evidence asymmetries in §5.
* `serve` is a bootstrap server. It is not a hardened production front end and
  this document makes no such claim.

## 11. Forwarded to later phases

Implemented by nobody in Phase 1; recorded so that their absence is deliberate
rather than forgotten:

| Item | Phase |
|---|---|
| Middleware (`use`, `next`), route groups, `mount` | 2 |
| Header accessors, `bearer_token`, typed state | 2 |
| Radix/compact router, conflict diagnostics, normalization policy | 3 |
| Request buffer retention and pooling | 3 |
| Trusted proxies, robust shutdown, configurable timeouts | 4 |
| `core:net/http` migration, streaming, WebSocket, uploads, static files | 5 / future |
| OpenAPI generation | future |

Confirmed absent from the public surface: middleware, groups, radix, wildcard,
typed state, `user_data`, `locals`, dynamic context map, header accessor,
configurable body limit, configurable timeouts, recovery, uploads, static files,
OpenAPI, WebSocket, streaming, public transport injection, public `Response`, a
second handler shape, and aliases. The freeze gate rejects any exported symbol
carrying Phase-2+ vocabulary.

## 12. Conditions of human acceptance

The freeze becomes effective only when all of the following hold:

1. `build/check.sh` is green at `PASS=10 FAIL=0 SKIP=0` on a clean checkout.
2. The ledgers read 32 + 2 = 34 and the snapshot diff is empty.
3. The independent VPS verifier reproduces both, from a clean archive, on the
   exact public commit, with the same pinned toolchain.
4. A human reviews and merges the WP11 pull request.
5. A human confirms one further verifier run on the merged commit on `main`.

Tag, semantic version and release are **not** granted by this document and
remain the owner's decision. No agent may merge, tag or publish.


---

## Amendment 1 — WP14: `test_request` carries an optional body

**Date:** 2026-07-19. **Authority:** owner, ADR-021 (as amended).
**Ledger effect: none.** 32 application + 2 test-support = 34, unchanged.

Phase 1 froze `test_request` at method + path. The consequence, unnoticed until
the post-Phase-1 audit measured it, was that a handler calling `web.body` could
never reach its success path in memory — it always saw `invalid_json`. The
framework's own tests reached it only by copying `web/*.odin` into a throwaway
package, which an application cannot do.

The frozen line changes from:

```
test-support	proc	test_request :: proc(a: ^App, method: Method, path: string) -> Recorded_Response
```

to:

```
test-support	proc	test_request :: proc(a: ^App, method: Method, path: string, body: string = "") -> Recorded_Response
```

**No symbol is added or removed.** The default keeps every existing call site
compiling and behaving exactly as before, which the gate asserts directly
(`tests/wp14-public-surface/contract_test.odin::wp14_the_three_argument_form_is_unchanged`).

**Why a default parameter and not a procedure group.** A group over `@(private)`
members renders in `odin doc` as member names only, so the snapshot would have
pinned this symbol's *name* while leaving its parameters free to change —
measured, and now rejected outright by `build/check_phase1_freeze.sh`. A default
parameter keeps the entire signature inside the frozen record.

**This is the amendment path working, not a breach of it.** Freezing never meant
"never changes"; it meant "changes only with evidence and a recorded amendment".
The gate's named assertions still hold — a snapshot cannot be refreshed to
launder a change, because they encode the decision rather than the current
state.

### One consequence worth recording

The 4 MiB cap is now reachable in memory, and it returns **413** — which has no
member in the public `Status` enum, because Phase 1 deliberately kept it private
(§4). So `Recorded_Response.status` can hold a value that is not a valid
`Status`, and testing the cap requires an integer comparison:

```odin
testing.expect_value(t, int(res.status), 413)
```

That is the frozen design meeting the new capability rather than a defect, but a
user will meet it the first time they test the cap, so it is pinned by
`tests/wp14-public-surface/contract_test.odin::wp14_the_body_cap_holds_on_the_memory_transport`.


---

## Amendment 2 — WP14: `test_request` carries an optional query string

**Date:** 2026-07-19. **Authority:** owner, ADR-021 (scope as accepted).
**Ledger effect: none.** 32 application + 2 test-support = 34, unchanged.

`web.query`, `web.query_int` and `web.query_int_or` are frozen Phase-1 symbols,
and none of them could be exercised through `test_request`: the facade filled
`Inbound.path` and left `Inbound.query` empty, so every lookup missed. Three
frozen public procedures were untestable without opening a socket.

The frozen line becomes:

```
test-support	proc	test_request :: proc(a: ^App, method: Method, path: string, body: string = "", query: string = "") -> Recorded_Response
```

`query` is a second fully visible default parameter, for the reason in
Amendment 1: both defaults appear in `odin doc`, so the entire callable contract
stays inside the frozen record. Query-only calls read
`web.test_request(&app, .GET, "/search", query = "q=hello")`; the named-argument
form was verified to compile on the pinned toolchain before the signature was
frozen.

**Query is carried separately from the path**, exactly as the real adapter does
it — the transport splits the request target before the core sees it, so a `?`
inside `path` is not a query string here either. Pinned by
`tests/wp14-query/contract_test.odin::wp14_query_is_not_part_of_the_route_path`.

### What is deliberately NOT in this amendment

**Request headers.** Phase 1 exports no header accessor, so a `headers`
parameter would be **write-only** — settable, and readable by nothing. It moves
to **WP19**, alongside `web.header` and `web.bearer_token`, so it arrives with a
test that can assert something. `Header_Pair` is not exported and no test-only
header type is introduced.

**Response-header recording.** `Recorded_Response` still carries only `status`
and `body`. That decision belongs to Phase 4, where CORS and cookies create the
first real need.

## Amendment 3 — WP17: middleware (`use`, `next`) joins the application ledger

**Date:** 2026-07-19. **Authority:** owner — the approved Phase-2 ledger
(`planning/phase-2-spec.md` §9.2, PR #30 review) assigns `use` and `next` to
WP17 under ADR-005 and ADR-019, both settled.
**Ledger effect: application 32 → 34.** 34 application + 2 test-support = 36.
The Phase-1 core of 32 symbols is unchanged: no frozen signature moved, no
field was added to a public type, and `odin doc` renders the two new rows and
nothing else (the snapshot diff at this amendment was exactly two added
lines).

The two recorded lines:

```
application	proc	next :: proc(ctx: ^Context)
application	proc	use :: proc(a: ^App, middleware: Handler)
```

There is NO `Middleware` type (D-12.1: a distinct proc type converts implicitly
in both directions on the pinned toolchain — no call-site cost, no protection
either). Chains are flattened at registration into an App-owned pool and routes
store index pairs, never `[]Handler` (spec §2.2, WP12 P8). Post-`next`
behaviour is specified and tested (ADR-022 = B1). App-level middleware observe
404/405 misses, in `bare()` too (ADR-023). `use()` after any registration or
after the first dispatch rejects the application fail-closed with the
owner-approved diagnostic (ADR-019; the diagnostic additionally names the count
of already-registered routes and the first unprotectable pattern, composed
through a fixed buffer — no `core:fmt`).

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `use` | A | WP17 | `tests/wp17-public-surface/contract_test.odin::wp17_use_and_next_signatures_are_pinned` | `tests/wp17-public-surface/contract_test.odin::wp17_mis_ordered_auth_program_does_not_serve_the_protected_route` | `docs/middleware.md::web.use` | App owns the global list and chain pool; lazy; freed once by `destroy` |
| `next` | A | WP17 | `tests/wp17-public-surface/contract_test.odin::wp17_use_and_next_signatures_are_pinned` | `tests/wp17-internal/wp17_internal_test.odin::wp17_second_next_is_a_silent_noop_and_the_handler_runs_once` | `docs/middleware.md::web.next` | reads the per-request cursor; allocates nothing; never rewinds |

One consequence recorded honestly: the §11 forwarded-items table still lists
middleware as "forwarded to Phase 2" — that stays true as a statement about
Phase 1. This amendment is the record that Phase 2 (WP17) delivered it.

## Amendment 4 — WP18: route organisation (`Router`, `router`, `mount`)

**Date:** 2026-07-19. **Authority:** owner — the approved Phase-2 ledger
(`planning/phase-2-spec.md` §9.2) assigns the three names to WP18 under
ADR-024 (ACCEPTED) and ADR-025 (ACCEPTED as option B).
**Ledger effect: application 34 → 37.** 37 application + 2 test-support = 39.
The snapshot diff at this amendment was exactly three added lines; no
existing row changed a byte.

The three recorded lines:

```
application	proc	mount :: proc(a: ^App, prefix: string, r: ^Router)
application	proc	router :: proc() -> Router
application	type	Router :: struct {using app: App}
```

**The §9.2 guard note, resolved.** The plan projected `use`, `destroy` and the
five verbs becoming procedure groups so Router variants add zero names; the
freeze gate rejects a group over `@(private)` members (unfreezable, ADR-021 as
amended), and exporting the members would have grown the ledger far past the
approved 44. The shape chosen instead: `Router` embeds an `App` with `using`
(subtype polymorphism), so `^Router` converts to `^App` implicitly at every
existing call site — zero new names beyond the approved three, zero procedure
groups, and the five verb signatures plus `use`/`destroy` stay byte-identical
(ADR-025 B's constraint holds literally). Compile-probed on the pinned
toolchain before implementation: all seven call sites accept `^Router`
unchanged; `^App` where `^Router` is expected is a compile error, so `mount`
stays Router-only; `odin doc` renders the using-field fully, so the snapshot
pins it. No `web.group` exists and none ever will (ADR-024, G-01).

Fail-closed rules carried by the mechanism (ADR-019 family, all tested):
`use` after a route applies inside a Router; mounting a poisoned Router
poisons the receiving App; `mount` counts as a registration; `mount` closes
the Router (late registration or a second mount fails closed); an invalid
prefix — one that does not begin with `/`, or ends with `/` — rejects the
App with a diagnostic naming the prefix, composed through a fixed buffer,
never `core:fmt`.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `Router` | A | WP18 | `tests/wp18-public-surface/contract_test.odin::wp18_public_signatures_are_pinned` | `tests/wp18-internal/wp18_internal_test.odin::wp18_app_and_router_each_release_their_own_storage_exactly_once` | `docs/canonical-patterns.md::Router` | embeds App via `using`; own storage, destroyed exactly once, never copied |
| `router` | A | WP18 | `tests/wp18-public-surface/contract_test.odin::wp18_public_signatures_are_pinned` | `tests/wp18-internal/wp18_internal_test.odin::wp18_an_unmounted_router_leaks_nothing` | `docs/canonical-patterns.md::web.router` | returns Router by value; allocates nothing; no default responses |
| `mount` | A | WP18 | `tests/wp18-public-surface/contract_test.odin::wp18_public_signatures_are_pinned` | `tests/wp18-internal/wp18_internal_test.odin::wp18_nested_routers_outer_use_before_inner_use_before_handler` | `docs/canonical-patterns.md::web.mount` | COPIES into the App; closes the router; counts as a registration |

## Amendment 5 — WP19: request header lookup (`header`, `bearer_token`)

**Date:** 2026-07-19. **Authority:** owner — the approved Phase-2 ledger
(`planning/phase-2-spec.md` §9.2) assigns both names to WP19 ("plan WP19, no
new decision"); the behaviour contract is `planning/phase-2-plan.md` §WP19.
**Ledger effect: application 37 → 39.** 39 application + 2 test-support = 41.
The snapshot diff for this amendment was exactly two added application lines.

The two recorded lines:

```
application	proc	bearer_token :: proc(ctx: ^Context) -> (value: string, ok: bool)
application	proc	header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool)
```

Both are PURE lookups — no response side effect (the documented asymmetry with
the extractors: an absent header is routinely not an error), nothing logged
(values are attacker-controlled; the WP6 `core:log`/`core:fmt` ban holds), no
allocation, `(value, ok)` with no `#optional_ok` (ADR-002). Names compare
case-insensitively with ASCII folding; duplicates: first occurrence wins (the
WP5 D4 rule); an empty value is present. `header` reads the EFFECTIVE request
header: the private ADR-027 overlay first, then what arrived — WP19 ships the
read path, WP23 the writer. `bearer_token` parses RFC 6750 strictly (scheme
case-insensitive, exactly one space, non-empty token, no whitespace tolerance)
and returns the token verbatim, never trimmed or normalised. Returned values
are VIEWS invalidated at request end — the WP2 view test is ported. **Audit
A-8 is resolved**: the per-request header materialisation the transport has
performed since WP8 is now read by these two procedures.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `header` | A | WP19 | `tests/wp19-public-surface/contract_test.odin::wp19_public_signatures_are_pinned` | `tests/wp19-internal/wp19_internal_test.odin::wp19_header_value_is_a_view_invalidated_by_buffer_reuse` | `docs/canonical-patterns.md::web.header` | returns a view over transport memory; overlay consulted first; allocates nothing |
| `bearer_token` | A | WP19 | `tests/wp19-public-surface/contract_test.odin::wp19_public_signatures_are_pinned` | `tests/wp19-internal/wp19_internal_test.odin::wp19_bearer_rejects_every_malformed_shape` | `docs/canonical-patterns.md::web.bearer_token` | strict RFC 6750 parse; token verbatim, never normalised; allocates nothing |

## Amendment 6 — WP19: `test_request` carries optional request headers

**Date:** 2026-07-19. **Authority:** owner, ADR-021 (scope as accepted) and
spec §9.3, which pre-authorised exactly this mechanism.
**Ledger effect: none.** Test-support stays 2 — the §9.3 contingency (a new
public type forcing the number up) was NOT needed.

The frozen line becomes:

```
test-support	proc	test_request :: proc(a: ^App, method: Method, path: string, body: string = "", query: string = "", headers: []string = nil) -> Recorded_Response
```

`headers` is the THIRD fully visible default parameter, on Amendment 1/2's
exact terms: the whole callable contract stays inside the frozen record and
every earlier call shape compiles unchanged (pinned by the amended
`tests/wp7-public-surface/contract_test.odin::wp7_test_request_signature_is_pinned`).

**Representation choice, presented.** Each element is one header line,
`"Name: value"` — split at the FIRST colon, optional whitespace trimmed around
the value (RFC 9110 field parsing, i.e. exactly what a socket delivers to the
core), inner colons kept, a colon-less element is a name with an empty value.
Considered and rejected: a public pair type (grows a ledger — needs owner
approval, and §9.3 said avoid if expressible); alternating name/value strings
(silently truncatable on an odd count, teaches nothing about wire form). The
header lines travel the SHARED driver pipeline as neutral pairs, so nothing
downstream can tell the two transports apart (R-10).

## Amendment 7 — WP20: the typed framework-error observer

**Date:** 2026-07-19. **Authority:** owner — ADR-026 (ACCEPTED, option A) and
the approved Phase-2 ledger (`planning/phase-2-spec.md` §6, §9.2).
**Ledger effect: application 39 → 42.** 42 application + 2 test-support = 44.
The snapshot diff for this amendment was exactly three added lines.

The three recorded lines:

```
application	proc	observe :: proc(a: ^App, observer: proc(event: Framework_Event))
application	type	Framework_Error :: enum {None, Response_Marshal_Failed, Body_Decode_Failed, Body_Consumed_Twice, No_Response_Committed, Invalid_Serve_Port, Serve_Listen_Failed, Use_After_Route}
application	type	Framework_Event :: struct {kind: Framework_Error, method: Method, route: string, status: Status, payload_type: typeid}
```

`Framework_Error` is the pre-existing private closed enum made public
unchanged. It carries **eight** members, not the seven §6.1 listed: WP17
ratified `Use_After_Route` after that section was written, and the spec's own
rule is that the enum "grows only when a work package ratifies a new member" —
so the eighth member is recorded here rather than silently absorbed.

**The redaction constraint is enforced by the gate, not by convention**
(§6.2, HARD). `build/check_public_api.sh` now asserts, on every run: the
event's field set is exactly the ratified five; **no field whose type mentions
`string` may be named anything but `route`** (so `path: string`,
`message: string` or `headers: []string` each fail the build); `observe` keeps
its exact signature; and the number of `framework_report` call sites equals
the number of observer emissions, so a future failure cannot be reported
without being observable. All four assertions were verified to FAIL against a
deliberate mutation before being trusted.

Two properties are stronger than the specification anticipated, and are
recorded as such rather than restated loosely:

* §6.3 says an observer that attempts to respond is stopped by the
  single-commit guard. With the accepted signature an observer receives the
  **event by value and nothing else** — no `^Context` — so responding is
  impossible **by type**; the guard is never reached because there is nothing
  to write through.
* `status` is read **after** the framework commits its answer, so it is the
  status actually sent rather than a prediction. Failures outside a request
  (the `serve` path) carry `method = .UNKNOWN`, `route = ""` and the zero
  `Status`: the event declines to invent values it cannot supply.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `observe` | A | WP20 | `tests/wp20-public-surface/contract_test.odin::wp20_public_signatures_are_pinned` | `tests/wp20-internal/wp20_internal_test.odin::wp20_last_observer_wins` | `docs/ai-context.md::observe` | one procedure pointer on the App; last wins; owns no storage |
| `Framework_Event` | A | WP20 | `tests/wp20-public-surface/contract_test.odin::wp20_public_signatures_are_pinned` | `tests/wp20-internal/wp20_internal_test.odin::wp20_the_event_survives_the_request_by_value` | `docs/ai-context.md::Framework_Event` | passed by value; `route` is an App-owned pattern valid until `destroy` |
| `Framework_Error` | A | WP20 | `tests/wp20-public-surface/contract_test.odin::wp20_public_signatures_are_pinned` | `tests/wp20-internal/wp20_internal_test.odin::wp20_marshal_failure_is_observed_once` | `docs/ai-context.md::Framework_Error` | closed enum, value type; grows only by ratification |

## Amendment 8 — WP22: the `logger` middleware

**Date:** 2026-07-20. **Authority:** owner — the approved Phase-2 ledger
(`planning/phase-2-spec.md` §9.2, row `logger`) and `planning/phase-2-plan.md`
WP22, which the spec records as carrying **no new decision**.
**Ledger effect: application 42 → 43.** 43 application + 2 test-support = 45.
The snapshot diff for this amendment was exactly one added line.

The recorded line:

```
application	proc	logger :: proc(ctx: ^Context)
```

`logger` is a `Handler` value, not a constructor and not a configurable object.
That is the whole shape: there is no `logger_with(...)`, no level, no sink and
no format argument, because every one of those would be a second public name
for an operation that already has one (G-01) and would freeze a configuration
contract Phase 4 owns.

**It is OPT-IN.** `web.app()` does not install it. G-08 forbids inventing a
default, and the phases document makes only recovery default-on; an application
that never writes `web.use(&app, web.logger)` logs nothing and links none of
this code.

**What the line may contain is frozen with the symbol**, because for this
component the OUTPUT is the contract. Method, registered route pattern, and
committed status — nothing else. Never the raw path, the query string, a header
name or value, a body byte, or a captured parameter value. The route field
carries the same low-cardinality identity rule §6.2 imposes on
`Framework_Event`, and for the same reason: on a miss there is no pattern, so
the field is `-` and does **not** fall back to the path.

Three properties are recorded because they are the ones a later change would
silently break:

* **Truncation is observable.** The line is composed in a fixed stack buffer
  bounded by `LOGGER_LINE_MAX`. A route field that does not fit is cut on an
  escape-unit boundary and marked `...[truncated]`, and the status still
  follows the mark. Growing the buffer would defeat the fixed buffer and
  re-import the per-request allocation it exists to avoid; dropping the line
  would make the logger lie by omission about traffic it saw. Both are excluded
  by tests, and a positive control asserts an ordinary pattern is **not**
  marked.
* **The status is read, never predicted.** The line is written after `next`
  returns (ADR-022 B1 is what makes that legal to promise). When the chain
  committed nothing, the field is `-`: the driver's 500 finalization happens
  after dispatch returns — after this middleware's frame is gone — so the
  logger did not see it, and says so rather than inventing it. That failure is
  reported through the WP20 observer, which is the channel that does see it.
* **It costs nothing when unused.** No import at all: not `core:log` (WP6
  measured ~37 KiB added to every application, referenced or not), not
  `core:fmt`. An application that never names `web.logger` links **zero**
  logger symbols, proven with `nm` against a positive control in
  `build/check_wp22_controls.sh` (control 7). What is NOT claimed, because it
  is not testable here: byte-identity of the binary. The pinned toolchain does
  not build reproducibly — five builds of an identical tree produced five
  distinct binaries — so byte-identity fails for a tree compared against
  itself. Recorded as a plan amendment rather than quietly downgraded.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `logger` | A | WP22 | `tests/wp22-public-surface/contract_test.odin::wp22_public_signature_is_pinned` | `tests/wp22-public-surface/contract_test.odin::wp22_public_never_emits_query_header_or_body` | `docs/middleware.md::web.logger` | a `Handler` value; composes into a fixed STACK buffer no response can alias; owns no storage; consults the commit guard through `logger_status` before reading response state |

## Amendment 9 — WP23: the `request_id` middleware and its trust policy

**Date:** 2026-07-20. **Authority:** owner — ADR-027 (ACCEPTED, option A) and
the approved Phase-2 ledger (`planning/phase-2-spec.md` §9.2).
**Ledger effect: application 43 → 44.** 44 application + 2 test-support = 46.
The snapshot diff for this amendment was exactly one added line.

The recorded line:

```
application	proc	request_id :: proc(ctx: ^Context)
```

**+1, not +2.** ADR-027 closed the `request_id_value` accessor contingency: the
effective ID is read through `web.header(ctx, "X-Request-Id")`, the one
canonical name for reading a request header (G-01). The cost of that choice is
declared rather than discovered — WP19 already documents `header` as returning
the **effective** request header, and this is the work package that makes the
word load-bearing.

**The trust policy is the deliverable, and it is frozen with the symbol.** A
client-supplied `X-Request-Id` is honoured **only** if it matches charset
`[A-Za-z0-9._-]` and length 1..64. Everything else — too long, empty, a space,
a semicolon, a control byte, non-ASCII, and above all CR or LF — causes the
value to be **discarded** and a fresh ID generated. Discarded is absolute: the
rejected bytes are never echoed, never written to the overlay, never logged,
and never reachable by a handler. There is no sanitising pass, because a
repaired attacker value is still an attacker value.

**The attack this closes** is CR/LF response-header injection. The charset
makes it impossible by construction rather than by a sanitiser that must be
remembered at every write site; the suites send `\r\n` anyway, because a
construction argument is a claim until something asserts it.

Four properties are recorded because a later change would break them silently:

* **The ID is NOT unguessable, and is never authentication.** Generation is a
  per-process seed (mixed from two ASLR-derived addresses — no import, see
  below) plus a monotonic counter: enough to be unique, deliberately not enough
  to be unpredictable. `core:crypto` is not imported, partly because a request
  ID must not be mistaken for a secret.
* **No dependency was added.** `web`'s direct-import set stays at the five
  pinned in `build/phase1-direct-dependencies.txt`. A cycle counter
  (`base:intrinsics`) or a clock (`core:time`) would each have grown it for a
  value that is explicitly not a secret.
* **The header is APPENDED, never seeded first.** WP4 ratified `Allow` first
  and `Content-Type` second for a 405, and a merged WP17 test pins both by
  index; seeding at slot 0 would have renumbered them. `RESPONSE_HEADER_MAX`
  grows 2 → 3.
* **It is attached where response headers are BUILT**, not by the middleware's
  unwind code, which is what puts it on a 404, a 405 **and** the driver's
  standardized 500. WP22 measured that the driver finalizes a missing response
  after the chain has unwound — a middleware stamping on the way out would miss
  exactly the response an operator most needs to correlate.

**The counter is not atomic**, and that is a stated assumption: one server per
process (audit R-10) with a single-threaded event loop. Phase 4 owns
concurrency and owns this line with it.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `request_id` | A | WP23 | `tests/wp23-public-surface/contract_test.odin::wp23_public_signature_is_pinned` | `tests/wp23-public-surface/contract_test.odin::wp23_public_crlf_is_never_echoed` | `docs/middleware.md::web.request_id` | a `Handler` value; the effective ID is copied into fixed request-local storage on the Context, viewed by the committed response and by the overlay; owns no allocation |

## Amendment 10 — WP34: route identity (`route`)

**Date:** 2026-07-20. **Authority:** the **ADR-029 delegation**
(`planning/adrs.md` §ADR-029, and the resolution table at
`planning/phase-3-plan.md` §2b, which records WP34 as *"Approved: +1 symbol"*).
This is the **first Phase-3 amendment**, and the first one whose authority is a
delegation rather than a direct owner decision — recorded here in those words,
because an amendment that cannot say who authorised it is not evidence.
**Ledger effect: application 44 → 45.** 45 application + 2 test-support = 47.
The snapshot diff for this amendment was exactly one added line; no existing
row changed a byte.

The recorded line:

```
application	proc	route :: proc(ctx: ^Context) -> string
```

**What it returns is the whole contract: the REGISTERED PATTERN, never the
request path.** `/users/:id`, not `/users/42`. This is C-2's constraint — the
OpenTelemetry `http.route` convention requires route identity to be
**low-cardinality** — and it is the reason the symbol earns its place: an
application that wanted the path already had `ctx.request.path`. What it could
not obtain was the identity that is safe to key a metric, a log field or a span
name on. A path-valued answer would create one time series per user id, and put
a user identifier into a dashboard nobody meant to put it in.

**The redaction rule is a GATE ASSERTION, not a convention.**
`build/check_public_api.sh` §8b pins the accessor's shape, requires its body to
be exactly `return ctx.private.route`, and — the assertion that actually does
the work — requires **every** write to that slot to be the matched entry's
`pattern`. A behavioural test can only check the routes someone thought to
write; this checks the assignment where the decision is made. It is the sibling
of the §8 assertion that keeps `Framework_Event` free of request-derived
strings, and the two exist together because one procedure returning the pattern
while another quietly returned the path is exactly how a redaction rule rots.

**Why the name is `route` and not `route_pattern`, `matched_route` or
`route_name` (G-01).** The framework already calls this value `route`: it is
the `route` field of `Framework_Event`, read from the same slot and carrying
the same string. A second name would mean an application reading
`web.route(ctx)` and an observer reading `event.route` had to be told they are
the same thing. `tests/wp34-public-surface` asserts they are, so a future
divergence is a red test rather than a documentation problem.

**No route means `""`,** and that is the answer rather than an error: on a 404
there is no route, and on a 405 no entry was selected for that method, so
naming the other method's pattern would name a route that did not run. A field
the framework cannot supply is left unpopulated rather than guessed (§6.2).

**Lifetime — the one exception, already on the books.** The result is a view
over **App-owned** storage, the pattern cloned at registration, and is valid
until `destroy`. It is therefore the only value reachable from a `^Context`
that is **not** request-scoped, and it is the same exception the Phase-2
lifetime ledger already records for `Framework_Event.route` — the same string,
now reachable by a second route. G-05 is unchanged for everything else.

**OQ-18 is closed by this amendment.** It recorded a stable route identity for
observability as internal and FUTURE. WP20 made the value visible to an
observer; WP34 makes it visible to the application that owns the request, under
the same redaction rule.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `route` | A | WP34 | `tests/wp34-public-surface/contract_test.odin::wp34_the_route_signature_is_pinned` | `tests/wp34-public-surface/contract_test.odin::wp34_a_parametric_route_reports_the_pattern_and_never_the_path` | `docs/ai-context.md::web.route` | App owns the pattern (cloned at registration, freed once by `destroy`); the result is a borrowed view valid until `destroy`, the single documented exception to request-scoped views; allocates nothing |

## Amendment 11 — WP37: typed application state (`app_with_state`, `state`)

**Date:** 2026-07-20. **Authority:** the **ADR-029 delegation**
(`planning/phase-3-plan.md` §2b: *"WP37 implements ADR-004 only"*), over
**ADR-004** (ACCEPTED, option A, with AMEND-1) and **ADR-028** (ACCEPTED,
option 1).
**Ledger effect: application 45 → 47.** 47 application + 2 test-support = 49.
The snapshot diff for this amendment was exactly two added lines; no existing
row changed a byte.

The two recorded lines:

```
application	proc	app_with_state :: proc(state: ^$T) -> App
application	proc	state :: proc(ctx: ^Context, $T: typeid) -> ^T
```

**Two symbols and not one**, because construction and access are different
operations with different failure modes: one rejects nil at boot, the other
asserts type identity per call.

**WHAT IS FROZEN IS THE SHAPE OF THE CALL SITE.** `web.state(ctx, App_State)`
carries no generic noise, and no handler signature acquires a type parameter.
That is precisely what ADR-004 chose option A for: option B — a parametric
`App(S)`/`Context(S)` — would have put a type argument on every handler in
every program. The declared price is a runtime assert instead of a compile
error, and it is paid where it can be seen: `state` asserts registration and
then EXACT `typeid` equality before the cast. There is no subtyping walk and no
"close enough"; casting a `^Config` to a `^Database` because both are pointers
is the defect the `typeid` exists to make impossible.

**A nil state rejects the application (AMEND-1),** through the ADR-019 poison
mechanism rather than a new one. An App that accepted nil would abort inside
the first request instead — the same failure, discovered later, in front of a
client.

**The `rawptr` is private and that is the whole basis on which G-03 permits
it.** Neither exported signature carries an untyped pointer: `app_with_state`
takes `^$T`, `state` returns `^T`. This is the narrowing
`build/check_public_api.sh` anticipated by name in the comment beside the ban.
Enforcing it exposed a hole in the check itself, closed in the same change: the
exported-declaration extractor treated any declaration line not ending in `{`
as complete, so a MULTI-LINE exported signature was never scanned at all. It
now follows a signature to its closing parenthesis, and stops at a procedure's
opening brace — a body is implementation, a signature is surface, which is what
G-03 always said in words.

**NO BACK-POINTER TO THE APP.** The driver copies the pointer and the `typeid`
onto the Context at the start of the request, exactly as it copies the WP20
observer. `Context_Internal` still holds no `^App` — the WP4 D3 decision stands
— and both transports get the state through one line on the shared pipeline
(R-10).

**ADR-028 IS THE OTHER HALF OF THIS AMENDMENT, and it ships nothing.**
Request-scoped typed state **does not exist and is not scheduled**. C-6 found
that Go's `context.WithValue` and Rust's `http::Extensions` exist for
type-erased, dynamically-keyed state crossing library boundaries — which
Druse does not have — and concluded that this SUPPORTS G-03. The honest
consequence is recorded rather than softened: the canonical auth pattern's
revalidation cost (WP24) stands until an ADR decides otherwise, and
`build/check_examples.sh` rejects a comment that schedules its removal.

**Lifetime, stated plainly because no assert can enforce it:** the pointed-to
value must outlive the App. The framework owns nothing here — `destroy` has
nothing to release, because it allocated nothing — and a pointer to a local in
a procedure that has returned is dangling with the type still right and the
memory still mapped. `examples/07-app-state` teaches the rule as LAYOUT: the
state and the App are both locals of `main`.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `app_with_state` | A | WP37 | `tests/wp37-public-surface/contract_test.odin::wp37_the_state_signatures_are_pinned` | `tests/wp37-public-surface/contract_test.odin::wp37_a_nil_state_rejects_the_application` | `docs/ai-context.md::web.app_with_state` | stores the CALLER's pointer and a `typeid`; owns nothing and allocates nothing; the caller owns the value and must outlive the App; `destroy` releases nothing here |
| `state` | A | WP37 | `tests/wp37-public-surface/contract_test.odin::wp37_the_requested_type_decides_the_result_type` | `tests/wp37-public-surface/contract_test.odin::wp37_a_handler_mutates_the_original_value` | `docs/ai-context.md::web.state` | returns the caller's own pointer, typed; asserts registration and exact `typeid` before the cast; borrows, owns nothing, allocates nothing |

## Amendment 12 — WP36: configurable limits (`Limits`, `DEFAULT_LIMITS`, `limits`)

**Date:** 2026-07-20. **Authority:** the **ADR-029 delegation**
(`planning/phase-3-plan.md` §2b: *"Approved: options struct + package default
constant; boot-derived immutable runtime"*).
**Ledger effect: application 47 → 50.** 50 application + 2 test-support = 52.
The snapshot diff for this amendment was exactly three added lines; no existing
row changed a byte.

The three recorded lines:

```
application	const	DEFAULT_LIMITS :: Limits{max_body = BODY_LIMIT, max_request_line = REQUEST_LINE_LIMIT, max_headers = HEADER_BLOCK_LIMIT}
application	proc	limits :: proc(a: ^App, l: Limits)
application	type	Limits :: struct {max_body: int, max_request_line: int, max_headers: int}
```

**THIS IS THE LEAST REVERSIBLE CHANGE IN PHASE 3 and the struct's size is the
whole defence.** A public options type is a promise per FIELD: once an
application writes `max_body`, removing or renaming that field breaks its build,
and *tightening a default* breaks its traffic without breaking its build — which
is worse. Adding a field later is cheap. Three fields ship, each because
something downstream already enforces it.

**THE DEFAULTS ARE THE SHIPPED VALUES, NOT NEW OPINIONS.** 4 MiB is the cap
Phase 1 fixed; 8000 is the vendored backend's own default for both text budgets.
An application that never mentions limits therefore behaves exactly as it did
before this amendment — the property that makes shipping the type safe. The
freeze snapshot records `DEFAULT_LIMITS` by the NAMES of its constants, so
`build/check_public_api.sh` additionally pins all three numbers; without that,
a default could change with the snapshot unmoved.

**IT ATTACHES TO THE APP, NOT TO `serve`, AND R-10 IS THE REASON.**
`test_request` never calls `serve`. A cap living on `serve` would make an
in-memory test answer 200 where a socket answers 413 — on exactly the boundary
a test suite exists to prove. The limits travel with the application, the shared
driver copies them onto every request beside the observer and the state, and
`serve` DERIVES the backend's options from them at boot. No `Limits` value
crosses the transport boundary: the adapter receives resolved integers, because
a public `web` type there would be the back-edge ADR-009 forbids.

**THE CONCURRENCY DECISION, recorded here because this is where the snapshot is
taken.** `limits` after the first dispatch **REJECTS** the application through
the existing poison mechanism. The snapshot model **sits beside ADR-019 and
ADR-023 and does not replace them**: `use()` after the first dispatch is still
refused for its own reason, and a test asserts that it still is. Nothing shipped
became weaker. Order relative to *routes* is deliberately unconstrained — a
limit protects every route equally, so there is no ordering hazard of the kind
ADR-019 exists for, and rejecting a safe program for resembling an unsafe one
would be a worse error than the one it prevented.

**A ZERO FIELD IS REJECTED.** `Limits{max_body = 1024}` leaves two fields at
zero, and the struct has no unset state to tell a forgotten field from a
deliberate one. Guessing would mean an application silently running on a mix of
its own values and the framework's. Start from `DEFAULT_LIMITS`.

**READ AND WRITE TIMEOUTS ARE NOT HERE, AND THAT IS A FINDING.** The plan named
them and set a stop rule, which this work package hit. The vendored server has
**no read or write deadline to configure**: `Server_Opts` carries
`limit_request_line` and `limit_headers` and nothing temporal, its only
`nbio.timeout_poly` uses are a fixed close delay and a one-second date tick, and
the request read in `vendor/odin-http/scanner.odin` still carries an unfinished-
work comment saying a timeout is wanted there. Real deadlines are
surgery inside the vendored event loop, not a field. Shipping without those
fields is the reversible arm: adding a field later is an amendment, while
shipping one that silently does nothing would be a lie with a version number on
it. **No document may claim Druse has configurable timeouts.**

**THE DERIVATION WAS MEASURED, as the plan required, and the measurement does
not distinguish the shapes on cost.** Consumer built at `-o:speed`, one POST
route binding a JSON body:

| Shape | Binary | Δ vs baseline | Request-path branches added | Allocations |
|---|---|---|---|---|
| `origin/main` (fixed 4 MiB constant) | 744,744 B | — | — | 0 |
| **Boot-resolved budget on the Context** (shipped) | 745,216 B | +472 B | **0** — a constant comparison became a field comparison | 0 |
| Configuration re-derived per request | 745,216 B | +472 B | 3 | 0 |

**Byte-identical**, so the amendment's reasoning is not vindicated by size and
this amendment says so. What separates the shapes is the branch count and the
semantics behind it: a per-request derivation can *discover a contradiction
under load*, which is the failure the boot-time validation exists to move to
boot. The evidence supports the choice on the second ground and is silent on the
first.

**ONE DECISION EMERGED DURING IMPLEMENTATION and is recorded rather than
smoothed over: a ZERO budget on the read path resolves to the default.** The
first cut compared directly against `ctx.private.limits.max_body`, which turned
every hand-built `Context` — every internal test suite that constructs one
without the driver — into an application that answers 413 to every body. That is
not failing closed; it is broken. The public contract is unchanged: `web.limits`
still REFUSES a partially-filled `Limits`, so an application can never choose a
zero, and the only way one arrives is a framework-internal omission. The public
API refuses ambiguity; the read path is defensive. `check_public_api.sh` §8c
still requires every constructor to set `DEFAULT_LIMITS`, now as defence in
depth rather than as the only thing standing between a slip and a dead
application — and `check_wp36_controls.sh` control 4 is a PAIR that pins both
halves: with a forgetful constructor the application must still serve (positive),
and with the safety net also removed it must not (negative).

**FINDING-C is discharged in this change.** The capacity ledger's row —
*"request body: 4 MiB, fixed, not configurable until Phase 3"* — is amended in
`planning/phase-2-freeze.md`, and the claim ledger gains a row for the new
promise with its own negative control.

**Freezing this exposed a hole in the freeze gate itself, closed in the same
change.** The signature extractor read procedures, procedure groups and types —
**never constants**. An exported constant is a public symbol whose VALUE is the
contract, so `DEFAULT_LIMITS` would have been invisible to the snapshot and its
value changeable with the frozen inventory unmoved. It is the same class of hole
the proc-group branch was written for. Constants are now extracted from the
FULL `odin doc` view, because the short view renders a struct constant as
`Limits{...}` and elides exactly the values that are the promise.

Evidence rows, same schema as §5:

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `Limits` | A | WP36 | `tests/wp36-public-surface/contract_test.odin::wp36_the_limits_surface_is_pinned` | `tests/wp36-public-surface/contract_test.odin::wp36_a_lowered_body_cap_is_enforced_exactly` | `docs/ai-context.md::web.Limits` | a plain value of three ints; owns nothing, allocates nothing; copied onto the App and onto each request |
| `DEFAULT_LIMITS` | A | WP36 | `tests/wp36-public-surface/contract_test.odin::wp36_the_defaults_are_the_values_already_shipped` | `tests/wp36-public-surface/contract_test.odin::wp36_an_application_that_never_configures_anything_still_works` | `docs/ai-context.md::web.DEFAULT_LIMITS` | a compile-time constant; unassignable, so no library can change another's defaults |
| `limits` | A | WP36 | `tests/wp36-public-surface/contract_test.odin::wp36_the_limits_surface_is_pinned` | `tests/wp36-public-surface/contract_test.odin::wp36_limits_after_the_first_dispatch_rejects_the_application` | `docs/ai-context.md::web.limits` | stores three ints on the App; validates at the call so the request path only compares; rejects fail-closed after the first dispatch |

## Amendment 13 — WP46: the request deadline joins `Limits`

**Date: 2026-07-21. Authority: the ADR-029 delegation, over ADR-031 (ACCEPTED,
as amended).**
**Ledger effect: NONE. 50 application + 2 test-support = 52, unchanged.**
No symbol is added. `Limits` gains a FIELD and `DEFAULT_LIMITS` gains the value
for it, which is a signature amendment rather than a ledger one — and it is
recorded here for exactly that reason: the snapshot diff was two changed lines,
and a changed line in a frozen signature needs the same ceremony as a new one.

The two amended rows:

```
application	const	DEFAULT_LIMITS :: Limits{..., max_request_time = REQUEST_TIME_LIMIT}
application	type	Limits :: struct {..., max_request_time: i64}
```

**WHY A FIELD RATHER THAN A NEW SYMBOL.** WP36 established the shape and its
cost: a public options struct is a promise per field. Adding a field is the
cheap direction of that asymmetry, and it keeps one answer to "how do I bound
this server" rather than two.

**WHAT IT BOUNDS, precisely, because the name could be read three ways.**
`max_request_time` is how long ONE request may take to **arrive** — first byte
to last. It is a REQUEST deadline, not an idle timeout: an idle timer is reset
by every byte, so a client trickling one byte per second resets it forever, and
that client is exactly the attack. It does **not** bound a handler; a slow
handler is the application's own time, and killing its connection would turn a
slow page into a broken one.

**THE TYPE IS `i64` NANOSECONDS RATHER THAN `time.Duration`**, and that is
FINDING-B rather than taste: `package web` may not import `core:time`, because
an application would then link a clock merely because the framework can
configure one. The neutral transport boundary carries a plain integer and the
adapter converts on the side where a clock is already linked.

**THIS IS THE FIRST DEFAULT THAT CHANGES BEHAVIOUR FOR AN APPLICATION THAT NEVER
MENTIONS LIMITS.** Every previous default restated what already shipped. This
one closes a connection that would previously have been held open forever. It is
a security fix rather than a tuning knob, and it is called out here because
WP36's own rule says tightening a default breaks traffic without breaking a
build — a rule this deliberately accepts rather than evades.

**THE NUMBER IS JUDGEMENT AND IS RECORDED AS SUCH** (the C-5 honesty rule).
Thirty seconds: no specification sets it, and the sources that discuss slowloris
name the technique and no figure. It is far longer than any legitimate client
needs to send a request over a working network — a large upload is bounded by
`max_body`, not by this — and far shorter than the "forever" that shipped
before.

**ZERO MEANS NO DEADLINE, and validation permits it** where the byte budgets
refuse zero. An operator must be able to ask for the previous behaviour
explicitly, and asking explicitly is the difference between a deliberate choice
and a forgotten field.

**ONE NEW DIRECT DEPENDENCY, and the gate made it deliberate.**
`web/internal/transport` now imports `core:time`. That is the FINDING-B line
being honoured rather than crossed: the clock lives on the transport side, where
`core:nbio` and the vendored server already link one, and **`package web` still
imports no clock** — which is why `max_request_time` is an `i64` and not a
`time.Duration`. The dependency snapshot and this manifest were updated
together, which is what the freeze gate refuses to let happen separately.

**Evidence.** `tests/wp41-fault` — the same laboratory that demonstrated the
hole. Its `phase_truncated_hold` and `phase_trickle` still assert the old
behaviour against a server with **no** deadline configured, and two new phases
assert the connection is closed when one **is**. The positive control runs
first: a deadline that also refused valid traffic would pass the new assertions
while breaking the server.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `Limits.max_request_time` | A | WP46 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp41-fault/fault_test.odin::phase_deadline_ends_a_held_connection` | `docs/ai-context.md::web.Limits` | a plain `i64` on a value type; owns nothing; converted to a duration at the transport boundary |

## Amendment 14 — WP44: `stop`

**Date: 2026-07-21. Authority: the ADR-029 delegation.**
**Ledger effect: application 50 → 51.** 51 application + 2 test-support = 53.
The snapshot diff was exactly one added line.

```
application	proc	stop :: proc(a: ^App)
```

**ONE SYMBOL, from a budget of two.** The WP38 usage lab measured the guarded
program at 23 of 25, and WP44 was allotted the remaining two concepts. It spends
one. The second was reserved for a drain-deadline field and **was not spent** —
see §"what could not be built" below, which is the more useful half of this
amendment.

**WHAT IT DOES.** `Serving → Draining`: admission ceases immediately, work
already in flight is allowed to finish, and `web.serve` returns when the drain
completes. It returns IMMEDIATELY rather than joining — **that is the shape a
signal handler needs**, and a `stop` that blocked could not be called from one.

**Safe from another thread and safe to call twice.** The backend's shutdown is
an atomic flag plus an event-loop wake-up, so a second `stop` during a drain is
a no-op rather than a second drain. That is what makes "cleanup runs exactly
once" (spec §1.3 obligation 4) true rather than hoped for, and it is tested by
calling `stop` twice and requiring the serve thread to still join.

**It does not destroy the App.** `stop` ends the server; `destroy` releases
storage. Merging them would make `stop` a teardown that cannot be called from a
signal handler — the exact case it exists for.

**WHAT COULD NOT BE BUILT, and this is recorded rather than quietly dropped.**
Spec §1.3 obligation 3 requires an ABSOLUTE drain deadline, and WP44 attempted
one as a vendored patch. **It did not stay contained, and it was withdrawn.**

Bounding the drain LOOP is not sufficient: the `nbio.run()` that follows it
waits on every pending operation, and a connection a client is holding open has
one. Closing those connections hard at the deadline did not help either. The
measured result was a drain that never terminated — worse than the unbounded
wait it was meant to replace.

**So obligation 3 is UNMET, and it is named as unmet.** Shipping a
`max_drain_time` field that did not bound the drain would have been precisely
the knob that lies this project refuses — the same rule that made WP36 ship
without timeout fields in the first place.

**The consequence for ADR-033 is not small: this is the counter-evidence that
ADR named in advance.** WP46's patch stayed contained and closed the ADR on
"keep"; WP44's did not. **ADR-033 is REOPENED** on exactly the trigger it wrote
for itself.

**A second finding, from the same work.** A handler that BLOCKS — `time.sleep`,
a synchronous call — blocks the event loop, and therefore blocks the drain and
any deadline check running on it. No deadline can bound that; it needs the
handler not to block. That is a documented consequence of ADR-030's
single-threaded decision and belongs with it.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `stop` | A | WP44 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp41-fault/fault_test.odin::phase_stop_is_idempotent_and_stops_admission` | `docs/ai-context.md::web.stop` | owns nothing; signals the running server and returns; idempotent and thread-safe |

## Amendment 15 — WP47: bounded admission joins `Limits`

**Date: 2026-07-21. Authority: the ADR-029 delegation, over WP40's reservation
rule.**
**Ledger effect: NONE. 51 application + 2 test-support = 53, unchanged.**
Two FIELDS, no symbols — the WP46 precedent, for the same reason: a public
options struct already exists and a second way to bound a server would be a
second answer to one question.

```
Limits.max_connections  int    1024 by default; 0 is unbounded
Limits.reserved_conns   int    16 by default; slots held back from admission
```

**WHY A LIMIT AT ALL.** Without one, concurrent connections are bounded only by
the operating system's file-descriptor limit — and reaching that limit is not a
graceful degradation. It is an `accept` failing for a reason the server did not
choose, at a moment it did not choose. **A server that refuses a connection is
degraded and honest; one that accepts everything until the kernel stops it has a
failure mode that is an accident.**

**THE RESERVATION IS AN INEQUALITY, AND THAT IS THE WHOLE RULE.** Admission is
refused at or below `max_connections - reserved_conns`, **never at zero**. The
fatal failure is not running out of capacity — it is running out and having none
left to shut down with. The test proves the gap rather than the ceiling: with a
budget of 6 and 2 reserved, the fifth connection is refused **while two slots
are still free**.

**A reservation that swallows its own budget is rejected at BOOT.**
`reserved_conns >= max_connections` would refuse every connection while looking
like a working configuration — a server that accepts nothing, discovered in
production. Fail-closed, with a diagnostic, where an operator is watching.

**Refusal is COUNTED, not logged per event** (WP40 §2.5). The transition is
logged once on entering the exhausted state and once on leaving it. Ten thousand
refused connections must not become ten thousand log lines: that turns a load
spike into an I/O storm, which is a denial of service the server performs on
itself.

**THE REFUSAL CLOSES RATHER THAN QUEUES.** A queue would be a second, invisible
limit with its own exhaustion behaviour, and the client learns the same thing
either way.

**The numbers are judgement, recorded as such.** 1024 sits below a typical
default descriptor limit so the framework's refusal arrives BEFORE the kernel's
— that ordering is the point of having a limit rather than inheriting one. 16
reserved is enough for a drain to close what is open and write final responses.

**Evidence.** `tests/wp41-fault`, with the positive control running FIRST: a
server whose limit is far above the load must serve everything, or the bounded
phase would pass against a server that refused every connection.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `Limits.max_connections` | A | WP47 | `build/phase1-public-signatures.txt` | `tests/wp41-fault/fault_test.odin::phase_admission_is_bounded_with_a_reservation` | `docs/ai-context.md::web.Limits` | plain `int` on a value type; the count lives per serving thread |
| `Limits.reserved_conns` | A | WP47 | `build/phase1-public-signatures.txt` | `tests/wp41-fault/fault_test.odin::phase_a_reservation_larger_than_the_budget_is_rejected` | `docs/ai-context.md::web.Limits` | as above; validated against `max_connections` at boot |

## Amendment 16 — WP48: the effective client address (`client_ip`, `trust_proxies`)

**Date: 2026-07-21. Authority: the ADR-029 delegation, over ADR-013 (ACCEPTED
in direction, option A).**
**Ledger effect: application 51 → 53.** 53 application + 2 test-support = 55.
The snapshot diff was exactly two added lines.

```
application	proc	client_ip :: proc(ctx: ^Context) -> string
application	proc	trust_proxies :: proc(a: ^App, prefixes: []string)
```

**TWO SYMBOLS, AND THE PAIR IS THE POINT.** One without the other would be
either a value you cannot use behind a proxy, or a value you cannot trust.

**THIS IS A SECURITY DECISION WEARING AN ERGONOMIC NAME.** `X-Forwarded-For` is
a request header; any client can send one. The things applications do with a
client address — rate-limit buckets, audit logs, allow-lists, abuse counters —
are exactly the things an attacker must not be allowed to choose. **Trusting the
header by default is not a convenience with a caveat; it is an authorization
bypass with a default.**

So the effective address is the **connected peer**, always, unless that peer
matches a prefix the operator registered — and only then is the leftmost
`X-Forwarded-For` entry believed.

**PREFIXES RATHER THAN CIDR, and the reason is the asymmetry rather than
effort.** A correct CIDR implementation needs IPv4 and IPv6 parsing, mask
arithmetic and the IPv4-mapped-IPv6 edge, and each is a place to be subtly wrong
inside a security boundary. **A wrong CIDR mask can trust a network you did not
mean to trust; a wrong prefix can only fail to trust one you did.** The failure
mode of the simpler design points the safe way. If a deployment genuinely needs
CIDR, that is evidence for a later package and adding it is a strengthening.

**REGISTRATION FAILS CLOSED, twice over.** An EMPTY prefix matches every peer —
it would trust the whole internet through one typo — and more prefixes than the
bound is refused rather than truncated: a dropped entry fails in the safe
direction, but leaves the operator's configuration quietly untrue, and a
security boundary that is quietly untrue is worse than one that refuses to
start. `TRUSTED_PROXY_MAX` is 8, with that behaviour-when-full stated, as the
capacity ledger requires.

**Evidence, and note where the suite spends its length: on the case where the
header must be IGNORED.** The tests run over `test_request`, which has no socket
and therefore no peer — which makes them the sharpest possible test of the
default: with no peer, nothing is trusted, and a forged header must be ignored
however the App is configured.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `client_ip` | A | WP48 | `tests/wp48-public-surface/contract_test.odin::wp48_the_signatures_are_pinned` | `tests/wp48-public-surface/contract_test.odin::wp48_an_untrusted_request_ignores_a_forwarded_header` | `docs/ai-context.md::web.client_ip` | returns a request-scoped VIEW over the peer string or the header; allocates nothing; copy to keep (G-05) |
| `trust_proxies` | A | WP48 | `tests/wp48-public-surface/contract_test.odin::wp48_the_signatures_are_pinned` | `tests/wp48-public-surface/contract_test.odin::wp48_an_empty_prefix_rejects_the_application` | `docs/ai-context.md::web.trust_proxies` | stores up to 8 caller-owned string views on the App; no allocation, no teardown; the caller's strings must outlive the App |

## Amendment 17 — WP49: `secure_headers`, and D-14.3 decided

**Date: 2026-07-21. Authority: the ADR-029 delegation.**
**Ledger effect: application 53 → 54.** 54 application + 2 test-support = 56.
The snapshot diff was one added line and **one CHANGED line** — the second is
the amendment that matters.

```
application  proc  secure_headers :: proc(ctx: ^Context)
test-support type  Recorded_Response :: struct {status: Status, body: string, headers: []string}
```

**THE MIDDLEWARE.** Three headers, chosen by a harsh rule: **a header is
included only if it has one correct value that needs no configuration and cannot
break an ordinary application.** `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`.

**What is absent is the more careful half.** CSP is the most valuable header
here and is *pure policy* — a CSP not written for the application breaks it, and
one loose enough not to break anything protects nothing. HSTS is meaningful only
over TLS, which this framework deliberately does not terminate; the proxy
holding the certificate is what should assert it. Cookie attributes need a
cookie API, and inventing one to have somewhere to put them would be accretion.

**It sets a FLAG the response builder reads**, not a stamp applied as the chain
unwinds — so the headers reach the automatic 404, the 405 and the driver's 500.
WP22 measured that the driver finalizes a missing response AFTER the chain has
unwound, and a 500 is exactly the response an attacker is most likely to read.

**D-14.3 IS DECIDED: `Recorded_Response` gains `headers`.** Phase 2 kept the
type at two fields and recorded the pressure as an open question. That was right
while the only response header worth asserting was one the framework set for
itself — an internal `package web` test could see it.

`secure_headers` ends that. Its entire purpose is letting an APPLICATION assert
its own security posture, and **an application that cannot observe the headers
it asked for has to test through a socket, which is exactly what `test_request`
exists to avoid.** A test-support API that cannot see what the framework sets
pushes people back to the thing it replaced.

**`[]string` in wire form**, not pairs and not a map: a pair type would export
`Header_Pair`, and a map would export a lookup contract and an allocation.
Strings are the vocabulary the bridge already shares.

**Two gate widenings, both recorded rather than absorbed.** The bridge gained
`last_headers` — the alternative was exporting a machinery type onto the public
surface, a far larger change. And `RESPONSE_HEADER_MAX` went 3 → 6, which is
arithmetic (2 + 1 + 3) rather than headroom, with an `#assert` that fails at
COMPILE time if a future writer is added without raising it.

**A defect in the gate itself, found by this amendment.** The
`Recorded_Response` field extractor used a bare `sed` substitution, which
REPLACES matching lines and passes everything else through — so a struct with
doc comments yielded comment text as though it were field names. It went
unnoticed because the struct had no comments until a field arrived that needed
explaining. Now `sed -n ... p`.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `secure_headers` | A | WP49 | `tests/wp49-public-surface/contract_test.odin::wp49_the_signature_is_pinned` | `tests/wp49-public-surface/contract_test.odin::wp49_the_headers_are_on_a_404` | `docs/ai-context.md::web.secure_headers` | a `Handler` value; sets one boolean; every name and value is a compile-time constant, so nothing is allocated and nothing torn down |
| `Recorded_Response.headers` | T | WP49 | `build/phase1-public-signatures.txt` (the changed row) | `tests/wp49-public-surface/contract_test.odin::wp49_recorded_response_exposes_header_lines` | `docs/ai-context.md::Recorded_Response` | owned by the recorder, valid until the next `test_request` on that App — the same lifetime `body` already has |

## Amendment 18 — WP50: `refused_connections`

**Date: 2026-07-21. Authority: the ADR-029 delegation, over the WP50 redaction
policy (`planning/phase-4-spec.md` §3).**
**Ledger effect: application 54 → 55.** 55 application + 2 test-support = 57.
One added line.

```
application	proc	refused_connections :: proc() -> int
```

**IT EXISTS BECAUSE THE POLICY DEMANDS IT, not because a counter felt useful.**
§3.5: *any component that can discard records must count what it discarded and
expose the count, because a metric that silently stops being emitted is worse
than no metric — it reads as "nothing happened".*

WP47 gave the framework the ability to refuse a connection. That is a discard,
and until this symbol existed it was an **invisible** one: a server under
admission pressure looked, from outside, exactly like a server nobody was
talking to.

**WHY A COUNT AND NOT A METRICS API.** A framework that exports a metrics
abstraction has chosen a metrics vendor for its users, and the shape of that
choice outlives the reasons for it. An integer an application reads and hands to
whatever it already uses is the smallest thing that discharges the obligation.
`web.observe` already covers framework FAILURES; this covers the one thing that
is neither a failure nor a request.

**Zero means two things and they are deliberately not distinguished** — no
server running, and nothing refused. A caller that needs to tell them apart is
asking whether a server is running, which WP44 decided this framework does not
answer.

**It carries no request-derived byte**, which is what places it inside §3.1's
permitted set rather than at its edge. An integer cannot leak a path, a header
or a body, and that property is what let this ship as observability at all.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `refused_connections` | A | WP50 | `tests/wp50-public-surface/contract_test.odin::wp50_the_signature_is_pinned` | `tests/wp50-public-surface/contract_test.odin::wp50_with_no_server_the_count_is_zero` | `docs/ai-context.md::web.refused_connections` | reads one integer from the running server through the named `g_server` exception; owns nothing, allocates nothing |

---

## Amendment 19 — WP59: `Limits.max_drain_time`

**Date: 2026-07-21. Authority: the ADR-029 delegation, over `planning/phase-5-spec.md`
§2.1, which fixed the success criterion and the failure handling BEFORE the
measurement.**
**Ledger effect: NONE. Application stays 55, test-support stays 2, union 57.**
A field on an existing type costs no name — the precedent is three of Phase 4's
five deliveries.

```
application	type	Limits :: struct {..., max_drain_time: i64}
application	const	DEFAULT_LIMITS :: Limits{..., max_drain_time = DRAIN_TIME_LIMIT}
```

**THIS FIELD WAS WITHDRAWN ONCE, AND THE WITHDRAWAL WAS CORRECT.** WP44 built it,
measured a drain that never terminated, and removed it rather than ship a knob
that bounded nothing. That decision is why this amendment can be written at all:
the gap stayed named in `docs/operations.md` instead of being papered over, and
ADR-033 reopened on the evidence.

**What changed is the mechanism, not the resolve.** WP44 bounded the drain loop
and found `nbio.run()` waiting behind it. WP58 measured the shape of that wait
and found the cause one layer lower: `scanner.odin` discarded the
`^nbio.Operation` returned by `recv_poly`, so the pending read was
**unreachable** and therefore uncancellable. Keeping that pointer — nine lines —
made cancellation possible, and cancellation ends the wait instead of bounding
it.

**IT IS ALSO A MEMORY-SAFETY FIX, and that is the part nobody was looking for.**
WP58 measured the alternative ending: releasing the clients' sockets let the
orphaned reads complete, `scanner_on_read` dereferenced a `^Connection` that
`connection_close` had already freed, and the process died with `free():
invalid pointer`. **A real deployment with idle keep-alive clients could hang on
shutdown or crash on it, and both were reachable before this amendment.**

**Measured, by `tests/wp58-drain/`:**

| Phase | Before | After |
|---|---|---|
| no connections | 990 ms | 990 ms |
| 8 idle keep-alive | never returned, then crashed | 987 ms |
| 1 connection held mid-request | never returned | 1.59 s, force-closed at the 1 s deadline |

**The default is ten seconds, and the number is judgement recorded as such**
(the C-5 honesty rule). No specification sets a shutdown deadline. It is chosen
against the only numbers that constrain it — systemd's `TimeoutStopSec` default
of 90 s and Kubernetes' 30 s grace period — because a drain deadline is
decoration unless it expires before the supervisor's kill.

**WHAT IT DOES NOT BOUND, and `docs/operations.md` says it in these words: a
handler that blocks.** The event loop is single-threaded (ADR-030), so a handler
that sleeps holds the very thread the deadline is enforced on. This is the same
honesty WP44 insisted on, and it is why the field is documented with its
exception rather than as a guarantee.

**A design attempt that failed, recorded because it looked right.**
`nbio.run_until(&flag)` with a timeout operation arming the flag is the obvious
shape for a bounded final drain. It is wrong: `run_until` loops while
`num_waiting() > 0`, and the arming timeout is itself outstanding — so a
shutdown with no connections waited the full deadline instead of returning at
once, turning the bound into a floor. Caught by WP58's positive control, which
went from 990 ms to 3 s. The shipped code ticks directly instead.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `Limits.max_drain_time` | A | WP59 | `build/phase1-public-signatures.txt` (struct shape frozen field-by-field) | `tests/wp58-drain/drain_test.odin::wp58_drain_anatomy`, three phases with a positive control first | `docs/operations.md` §4 and §10, `docs/ai-context.md::web.Limits` | stores one integer, validated at boot; allocates nothing; converted to a `Duration` at the transport boundary because `package web` may not import `core:time` (FINDING-B) |

**Rollback.** Set the field to zero and the previous behaviour returns exactly —
no deadline, no forced close. The vendored patches (9, 10, 11) are marked
`DRUSE PATCH — BRIDGE` per `vendor-policy.md` §8 and are expected to be
**deleted** when `core:net/http` lands in January 2027, not ported. Patch 10 is
the exception worth offering upstream regardless: the use-after-free it fixes is
upstream's, not this project's.

---

## Amendment 20 — WP60: `cors` and `Cors_Options`

**Date: 2026-07-21. Authority: ADR-034 (owner amendment), recorded in
`planning/phase-5-spec.md` §1 and `decisoes-do-dono.md`.**
**Ledger effect: application 55 → 57.** 57 application + 2 test-support = 59.
Two added lines.

```
application	proc	cors :: proc(a: ^App, o: Cors_Options)
application	type	Cors_Options :: struct {origins: []string, methods: string, headers: string, credentials: bool, max_age: int}
```

**`cors` WAS A RESERVED NAME AND THIS IS THE PHASE IT WAS RESERVED FOR.** It sat
in `check_public_api.sh`'s later-phase list from Phase 1 precisely so nothing
could take it before a work package argued for it. It leaves that list here,
which is the list doing its job rather than being overridden.

**WHY IT IS CONFIGURATION AND NOT MIDDLEWARE**, which is the decision the shape
turns on. Two reasons, both structural:

1. **The headers must reach every response.** Including the automatic 404, the
   405, an extractor's 400 and the driver's 500. WP22 measured that the driver
   finalizes a missing response AFTER the chain has unwound, so a stamping
   middleware misses exactly the responses a browser most needs to read — a
   page whose error is invisible shows its user a blank screen. The
   `secure_headers` precedent decided this once; this follows it.
2. **A preflight must be answered without running a handler.** A middleware
   cannot stop the chain, and this framework deliberately gives it no way to.

**THE SAFETY RULES ARE ENFORCED AT REGISTRATION**, and that is the whole value
of the symbol over a hand-written middleware. A CORS misconfiguration is not an
error the server notices — it works perfectly and quietly shares one origin's
authenticated data with another. So four configurations fail closed at boot:

| Refused | Why it is not merely wrong |
|---|---|
| `*` with `credentials` | The classic hole. No browser honours it, so the application looks broken, and the obvious workaround — echo whatever `Origin` arrives — is a real vulnerability |
| `*` beside named origins | Reads as "these, and also everyone", which is everyone |
| `*` in `headers` with `credentials` | The Fetch standard does not let that wildcard cover `Authorization`, so it permits less than it appears to |
| empty origin list | An allow-list that allows nothing is unfinished, not strict |

**WHAT IT ECHOES.** A listed origin comes back as itself, never the literal `*`,
always with `Vary: Origin` — echoing the wildcard would make every origin's
response look identical to a shared cache. An UNLISTED origin gets the response
with **no CORS header at all**: served, and unreadable by the page. Refusing
outright would break every same-origin browser POST, which also carries an
`Origin`, and would leak which origins are listed through the status difference.

**`methods` and `headers` are comma-joined strings rather than slices**, which
is a deliberate trade. They go on the wire verbatim, so taking them pre-joined
means the framework never builds a string at request time and never needs a
buffer to build it in. Slices would read better at the call site and would cost
an allocation or a copy on every preflight.

**Ownership: the strings are the CALLER's**, on the `trust_proxies` contract
exactly — read on the request path, so they must outlive the App, and string
literals are what every real call site passes. Only the LIST is copied, into a
bounded inline array, so the App never holds a slice header whose backing the
caller could resize.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `cors` | A | WP60 | `tests/wp60-public-surface/contract_test.odin::wp60_the_signatures_are_pinned` | `tests/wp60-public-surface/contract_test.odin` — twelve cases including the four fail-closed configurations; `tests/wp60-internal/wp60_internal_test.odin` — six preflight cases | `docs/ai-context.md::CORS`, fragment `phase5/cors` with a compiling fixture | stores a bounded inline config on the App; allocates nothing; the origin strings are the caller's |
| `Cors_Options` | A | WP60 | `build/phase1-public-signatures.txt` (struct shape frozen field-by-field) | `tests/wp60-public-surface/contract_test.odin::wp60_the_signatures_are_pinned` constructs every field | `docs/ai-context.md::CORS` | a by-value policy; owns nothing; `origins` is a caller-owned slice read only at registration |

**The preflight suite is INTERNAL, and that is the design working.** A preflight
is an OPTIONS request; `test_request` takes a `Method`; `Method` has no OPTIONS
member because HEAD and OPTIONS are resolved from the raw token before a
`Method` value exists. A public-surface suite that COULD send a preflight would
be evidence the frozen six-member enum had grown.

**Rollback.** Removing `cors` removes the feature completely: `Cors_Config` is
private, the request path reads a flag that is never set, and no other symbol
references either name. The one shared edit is `RESPONSE_HEADER_MAX`, raised
from 6 to 12 — a fixed array on the Context, no allocation either way.

---

## Amendment 21 — WP61: `static` and `Static_Options`

**Date: 2026-07-21. Authority: ADR-034, recorded in `planning/phase-5-spec.md` §1.**
**Ledger effect: application 57 → 59.** 59 application + 2 test-support = 61.
**Dependency ledger: `web` gains `core:os`** — the first change to
`build/phase1-direct-dependencies.txt` since Phase 1.

```
application	proc	static :: proc(a: ^App, prefix: string, dir: string, o: Static_Options = {...})
application	type	Static_Options :: struct {max_file_size: int, index: string}
```

**IT IS CONFIGURATION, NOT A ROUTER, for a mechanical reason.** A `Handler` is a
plain procedure with no captured state, so a handler produced by `static` could
not know which directory it belonged to. The App holds the mounts and the
request path reads them — the same shape `cors` takes, for the same reason.

**A MOUNT OWNS ITS PREFIX.** A request under it is answered from the filesystem
or answered 404; it never falls through to the router. That is the `location`
rule every reverse proxy already uses. The alternative — try the router, then
fall back to files — makes "why is my route shadowed?" depend on whether a file
happens to exist, which is a question nobody can answer from the source.

**THE REJECTIONS ARE THE FEATURE.** Every rule is a refusal, never a repair,
because a normaliser that gets it wrong produces a path the check already
approved: `..`, `%`, `\`, NUL, empty interior segments, a leading `.` on any
segment, a trailing `/`, anything that is not a regular file, and **every
symlink whatever it points at**.

Two of those deserve their reasons in the ledger:

- **`%` is refused outright.** Druse never decodes the path (WP31a,
  permanent), so `%2e%2e` would sail past a textual `..` check untouched and be
  decoded by something downstream. A file whose name needs percent encoding is
  not worth that.
- **All symlinks are refused, not just escaping ones.** The stat does not follow
  links, so a link reports its own type and is refused before anything resolves
  it. Resolving and then comparing against the mount root is a string comparison
  between paths that may be spelled differently, and **every wrong answer to
  that comparison serves a file it should not.** This was not theoretical: the
  first implementation did compare a resolved path against the root, and it
  silently 404'd *every* file because `stat` returns an absolute path while the
  mount was configured relative. The corpus caught it; a reviewer would not have.

**GUARDRAIL 3 WAS VIOLATED AND THEN FIXED, and the measurement is why the fix
exists.** Calling the file server directly from `driver_run` links `core:os`
into every binary: `examples/01-hello-world`, which serves no files,
**grew by 20 176 bytes.** The server is now reached through a proc pointer whose
only assignment is inside `static`, exactly as `test_teardown` is under G-11, so
the linker drops it — and `core:os` with it — from applications that mount
nothing. The residual is 1 936 bytes across WP60 and WP61 together: the pointer
field, the two inline config structs, and nothing executable.

**WHAT IT DOES NOT DO**, each with its reason recorded rather than omitted:
no file above `max_file_size` (8 MiB default) because responses are buffered
whole under ADR-014 and a 100 MB download is 100 MB of RSS; no `Last-Modified`
because an HTTP date needs a formatter linked into every application, and
`ETag` validates as well without one; no ranges, which need the partial-response
machinery streaming needs; no directory listing, which is a feature that leaks a
filesystem.

`STATUS_NOT_MODIFIED` carries 304 **without adding a public `Status` member**,
on the `STATUS_BODY_TOO_LARGE` precedent: the enum is frozen member-by-member,
and 304 is a cache negotiation the framework performs on the application's
behalf — no handler returns it, so no handler needs a name for it.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `static` | A | WP61 | `tests/wp61-public-surface/contract_test.odin::wp61_the_signatures_are_pinned` | `tests/wp61-public-surface/contract_test.odin` — twelve cases, nine of them rejections | `docs/ai-context.md::Static files`, fragment `phase5/static` with a compiling fixture | stores bounded inline mounts on the App; the prefix and directory strings are the caller's; the served bytes are allocated per request and owned by the `Response`, released by `response_destroy` |
| `Static_Options` | A | WP61 | `build/phase1-public-signatures.txt` (struct shape frozen field-by-field) | `tests/wp61-public-surface/contract_test.odin::wp61_a_file_over_the_cap_is_refused`, `::wp61_the_index_is_served_at_the_mount_root` | `docs/ai-context.md::Static files` | a by-value policy; owns nothing |

**Rollback.** Removing `static` removes the feature and the `core:os`
dependency with it: the mounts are private, the request path calls through a
pointer that is never assigned, and no other symbol references either name.

---

## Amendment 22 — WP63: `form_field`, `form_file`, `Uploaded_File`

**Date: 2026-07-21. Authority: ADR-034, scoped by `planning/phase-5-uploads-spec.md`
(WP62), which answered OQ-20's seven questions before any code was written.**
**Ledger effect: application 59 → 62.** 62 application + 2 test-support = 64.

```
application	proc	form_field :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool)
application	proc	form_file :: proc(ctx: ^Context, name: string) -> (file: Uploaded_File, ok: bool)
application	type	Uploaded_File :: struct {field: string, filename: string, content_type: string, bytes: []u8}
```

**OQ-20 CLOSES HERE, and four of its seven questions dissolved rather than
being answered.** They all presuppose a spool — bytes arriving, the framework
writing them to a temporary file, the handler receiving a path. This framework
has no spool: the body arrives WHOLE, bounded by `Limits.max_body`, and a larger
one is answered 413 before any handler runs (WP8 D3). So there is no temporary
file to own, nothing to clean up, no disk to fill, and no persistence to
transfer. The remaining three were already answered by shipped limits —
`max_body` is the quota, `max_request_time` (WP46) is the timeout, and the
truncated-body case is covered by `tests/wp41-fault/`.

**THE NEW POLICY IS TWO BOUNDS, and they exist because `max_body` bounds the
BYTES and not the WORK.** A 4 MiB body can be ten thousand parts, and a parser
that allocates once per part turns a bounded body into an unbounded loop — a
denial of service that passes every limit this framework had. So the part count
(32) and the per-part size (1 MiB) are bounded too, and the parse writes into a
fixed array on the Context rather than allocating. **The parser allocates
nothing:** every field it produces is a view over the request body.

**IT IS A BODY CONSUMER, on ADR-012's terms exactly.** The form readers and
`web.body` take the same single-use capability, and whichever runs first takes
it. Reading one body twice through two decoders is the ambiguity ADR-012 closed,
and multipart does not get an exemption from it.

**A MALFORMED FORM YIELDS NOTHING, never a partial parse.** A form parser that
salvages what it can hands the handler a missing field that looks like a field
the user left blank — and nobody debugging that suspects the parser.

**`filename` and `content_type` are the client's CLAIMS**, documented as such at
the field. The framework never uses the filename as a path, never sanitises it,
and says so: sanitising would imply it was safe afterwards. Generating a storage
name is the application's job, and OWASP's file-upload guidance is the reason
the type says "claim" rather than "type".

**THE HONEST LIMITATION, and `docs/operations.md` §3 carries it:** an upload
larger than `max_body` cannot be accepted at any setting that is not itself a
memory problem, because the body is held whole. Gin spools to disk through
`net/http`; this does not spool at all. **A framework that says so is more
useful than one discovered in production.** Large uploads belong at a proxy or
an object store, with a reference handed to the application.

**AMEND-P5-3 IS SATISFIED BY CONSTRUCTION:** the parser takes `[]u8` and knows
nothing else. When `core:net/http` replaces the adapter in January 2027, a
parser that only ever saw bytes keeps working; one that had learned where the
bytes came from would not.

| Symbol | L | Owner | Compile evidence | Behavior evidence | Docs | Ownership |
|---|---|---|---|---|---|---|
| `form_field` | A | WP63 | `tests/wp63-public-surface/contract_test.odin::wp63_the_signatures_are_pinned` | `tests/wp63-public-surface/contract_test.odin::wp63_a_form_is_parsed`, `::wp63_a_missing_field_is_reported`, `::wp63_malformed_bodies_yield_nothing` | `docs/ai-context.md::Multipart forms`, fragment `phase5/multipart` | returns a view over the request body; allocates nothing; takes the ADR-012 body capability on first use |
| `form_file` | A | WP63 | `tests/wp63-public-surface/contract_test.odin::wp63_the_signatures_are_pinned` | `::wp63_a_form_is_parsed`, `::wp63_a_field_is_not_a_file_and_a_file_is_not_a_field`, `::wp63_a_boundary_like_string_inside_content_is_safe` | `docs/ai-context.md::Multipart forms` | as above; `Uploaded_File.bytes` is a view valid for the request only |
| `Uploaded_File` | A | WP63 | `build/phase1-public-signatures.txt` (struct shape frozen field-by-field) | `::wp63_the_signatures_are_pinned` constructs every field | `docs/ai-context.md::Multipart forms` | a by-value record of views; owns nothing; must be copied to outlive the request (G-05) |

**Rollback.** All three are readers over a private parser and a private Context
field; removing them removes the feature with no other symbol affected. No
dependency is added — the parser uses `core:strings`, which `web` already had.

---

## Amendment 23 — WP68: honest JSON classification, no ledger growth

**Date: 2026-07-21. Authority: `planning/phase-6-spec.md` §5.1 and Amendments
1–2. Ledger effect: none; application remains 62 and test-support remains 2.**

**Dependency ledger: `web` gains `core:reflect` and `core:strconv`.** Both are
Odin standard-library packages under the repository's BSD-3-Clause license
(`$ODIN_ROOT/LICENSE`). Their sole owner is the private
`web/json_decode.odin` structural preflight: reflection maps the caller's
concrete destination to JSON fields, and `strconv` verifies the numeric string
coercions the pinned stdlib decoder already accepts. Neither type appears in a
public signature, and neither crosses the transport boundary.

**Why two dependencies are justified.** The WP67 experiment proved that the
standard decoder supplies neither an object-field stack nor an unknown-key
error. Reimplementing that information without RTTI would require a second
schema declaration or generated code, both larger public concepts explicitly
refused by the Phase-6 spec. Reimplementing numeric conversion would create a
second interpretation of values already owned by the stdlib. The two imports
therefore keep the implementation thin: standard grammar and conversion,
private structural comparison only.

**Cost evidence.** Two adjacent worktrees (WP67 parent `5db85d0` and WP68), the
same pinned `819fdc7` compiler and byte-identical build commands measured
`01-hello-world` at 966,720 versus 966,768 bytes: **+48 bytes** for an
application that never calls `body`. The JSON example measured 1,116,288
versus 1,133,768 bytes: **+17,480 bytes** when the feature is used. The result
shows that the linker removes practically the whole preflight when unused;
introducing registration or code generation to chase the residual 48 bytes
would oppose the project's simplicity goal. These exact measurements are
evidence, not a permanent size promise.

**Ownership and failure.** The preflight tree lives in a disposable dynamic
arena and is destroyed before the authoritative typed decode. Its field path
is a fixed request-local value and the error envelope uses the existing fixed
Context buffer. Malformed input is validated allocation-free first because the
pinned parser's partial-error cleanup consults the implicit allocator; the WP7
tracking test caught that mismatch and now pins zero leaks and zero bad frees.

**Rollback.** Removing `web/json_decode.odin`, the two 400 renderers and the
preflight call restores the pre-WP68 decoder behavior and removes both imports.
No signature, ledger row, Context field or transport contract changes.

---

## Amendment 24 — WP70: thread-safe framework core, no ledger growth

**Date: 2026-07-22. Authority: `planning/phase-6-spec.md` §3 and
`planning/phase-6-plan.md` WP70. Ledger effect: none; application remains 62
and test-support remains 2.**

**Dependency ledger:** `web` and `web/internal/transport` each gain
`core:sync`. Both are Odin standard-library imports. The first owns atomic App
publication and request-ID allocation; the second owns the short lifetime lock
around the private backend server pointer. No synchronization type appears in a
public signature.

**Ownership is the mechanism.** Before a real server starts lanes, `web.serve`
builds the lazy miss chain and publishes one immutable App snapshot. Late
configuration is refused without mutating or poisoning live state. Request
Contexts remain lane-local; the backend Date cache and connection map are
lane-owned. Atomics are reserved for counters and state transitions that are
genuinely shared.

**Patch 12 is a bridge, not a new foundation.** It elects exactly one backend
shutdown owner, makes the Date cache lane-owned and atomically aggregates
admission refusals. WP69's unchanged four-lane drain obligation previously
terminated with `Segmentation_Fault`; it is GREEN after the ownership repair.
The vendor policy, patch ledger and in-source markers all identify the change
for deletion with the bootstrap adapter.

**Evidence:** `build/check_wp70_controls.sh` owns an eight-thread deterministic
contention corpus, a sixteen-caller real-socket stop case and three semantic
mutations. The complete boundary, including the explicit exclusion of
application-owned `App_State`, observers' sinks and permanently blocking
foreign code, is recorded in `planning/phase-6-thread-safety.md`.

**Cost evidence:** adjacent worktrees at WP69 parent `1cd8175` and WP70, the
same pinned compiler and identical `01-hello-world` build commands, measured
967,248 and 971,616 bytes respectively: **+4,368 bytes** for the internal
thread-safe foundation. This is paid before WP71 enables multiple lanes and is
recorded explicitly rather than hidden in that feature's later measurement.

**Rollback.** No public name or signature changed. Removing the private
publication helpers, restoring the single-lane assumptions and dropping Patch
12 removes both direct imports and returns the previous implementation.

---

## Amendment 25 — WP71: bounded Handler concurrency, no ledger growth

**Date: 2026-07-22. Authority: `planning/phase-6-spec.md` §5.2 and
`planning/phase-6-concurrent-serving.md`. Ledger effect: none; application
remains 62 and test-support remains 2.**

**Shape and compile evidence.** Existing `Limits` gains
`max_handlers: int`; `DEFAULT_LIMITS.max_handlers` is `0`. The exact field and
constant shapes are compiler-derived in `build/phase1-public-signatures.txt`.
No new public name exists.

**Behavior and negative evidence.** `build/check_wp71_controls.sh` owns the
automatic, explicit-four, explicit-one, invalid-value and backend-suspension
cases. Mutants collapsing auto to one, accepting 257, leaving accept posted and
restoring lane-local admission are all rejected. The adapter-private resolver
is tested in a throwaway copy of the real transport package.

The first complete gate also found and repaired a pre-existing lane-local
admission count: `max_connections` is now claimed and released through one
server-wide atomic counter, and WP41's reservation corpus proves the limit is
not multiplied by `max_handlers`.

**Documentation and ownership.** `docs/operations.md`, `docs/ai-context.md`,
`docs/canonical-patterns.md` and `planning/phase-6-concurrent-serving.md`
document automatic 4..32, explicit 1..256, full saturation, application-owned
shared state and non-preemptible Handler code. The setting names Handler
capacity rather than backend threads, preserving adapter replaceability.

**Dependencies and cost.** The private adapter gains `core:os` and
`core:nbio`; neither appears publicly. Adjacent builds at WP70 main `19b9cb9`
and WP71, using equal-length output paths to avoid Odin's path-dependent binary
padding, measured `01-hello-world` at 970,312 and 975,784 bytes: **+5,472
bytes**. This pays for automatic capacity and the admission/cancellation bridge
even when the application leaves the field at its default.

**Rollback.** Remove the field, the two private imports, Patch 13 and the
adapter bracket. Restore the single-lane mapping. No route, Handler signature,
in-memory behavior or Phase-5 feature changes.

---

## Amendment 26 — WP72: concurrent-serving verdict, no ledger growth

**Date: 2026-07-22. Authority: `planning/phase-6-spec.md` §5.2 and
`planning/phase-6-plan.md` WP72. Ledger effect: none; application remains 62
and test-support remains 2. Dependency effect: none.**

WP72 adds no public name, field, signature or import. It is the combined gate
that permits the WP71 capacity to become the accepted default: the historical
drain and use-after-free obligation, concurrent stop, immutable registration,
request-ID uniqueness, slow I/O, 3,000 completed idle keep-alives and the
Phase-5 CORS/static/multipart paths remain green while three of four Handlers
are blocked by database-like synchronous work.

The scale laboratory raises its process-local soft descriptor limit to 8,192
because each in-process client consumes a descriptor beside its accepted
server socket. A 512-connection mutation fails before the 3,000th connection,
proving that the result owns the server-wide admission mechanism rather than
only the laboratory limit.

**Decision evidence:** `planning/phase-6-concurrency.md`, ADR-030 Amendment 1
and `build/check_wp72_controls.sh`. Full Handler saturation and arbitrary
non-preemptible foreign code remain explicit capacity boundaries; neither is
misrepresented as a drain guarantee.

**Rollback.** The evidence and ADR amendment are removable without changing a
binary. Runtime compatibility remains available through `max_handlers = 1`.

## Amendment 27 — WP-6.5.3: `is_draining`

**Date: 2026-07-23. Authority: ADR-040, from the production-readiness audit.**
**Ledger effect: application 62 → 63.** 63 application + 2 test-support = 65.
The snapshot diff was exactly one added line.

```
application	proc	is_draining :: proc(a: ^App) -> bool
```

**ONE READABLE BIT.** WP44 refused any readable lifecycle state, on the grounds
that a readable state invites a poll loop where a supervisor belongs. ADR-040
narrows that refusal, it does not overturn it: the supervisor's question
("restart this process") stays answered by the process exiting, but a load
balancer's question ("still route new traffic here") is a different one a real
deployment must answer, and a readiness probe reading one boolean on the
orchestrator's own schedule is not the busy poll WP44 warned against.

**WHAT IT DOES.** Reports whether `stop` has been requested. `false` before
`stop`, `true` after, and never back to `false` — an operator who asked for a
stop meant it. A readiness handler answers `503` while it is true, so the proxy
stops routing to a draining instance. It reads an atomic, allocates nothing, and
is safe from any thread; `stop` publishes the bit before asking the transport to
stop, so the answer is never behind the refusal.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `is_draining` | A | WP-6.5.3 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp58-drain/is_draining_test.odin::wp65_is_draining_is_false_until_stop` | `docs/ai-context.md::web.is_draining` | reads one atomic on the App; `false` before `stop`, `true` after, never back; owns nothing, allocates nothing |

**Rollback.** The symbol, its example and its evidence are removable without
changing any other binary; the drain machinery it reads predates it (WP44/WP58).

## Amendment 28 — WP90: `Limits.max_write_time` and `Limits.max_idle_time`

**Date: 2026-07-23. Authority: ADR-039 (ACCEPTED), delivered by Phase 7's
WP90 with the vendored transport in hand.** **Ledger effect: none.** Two
FIELDS on the frozen `Limits` record, on the field-cost precedent of
`max_request_time` (WP46), `max_drain_time` (WP59) and `max_handlers` (WP71):
a field pays signature, documentation and behaviour evidence, but adds no
name. 63 application + 2 test-support = 65, unchanged. The snapshot diff is
exactly the `Limits` row, gaining `max_write_time: i64, max_idle_time: i64`
after `max_request_time`.

**WHAT THEY DO.** `max_write_time` bounds how long one response may take to
SEND; at the deadline the connection is **reset**, not closed gracefully,
because a graceful close first flushes kernel-buffered bytes to the slow
reader at the client's own pace — the deadline would bound nothing observable
(the measured Phase-6.5 failure, recorded in ADR-039). `max_idle_time` bounds
the quiet gap between keep-alive requests; the clock stops when the next
request's bytes arrive and the close is graceful. Both are `i64` nanoseconds
(the FINDING-B rule: `package web` links no clock), both `0` = off, both
validated non-negative at `web.limits`, both enforced by the vendored
backend's deadline sweep as BRIDGE patches 19/20 with the raw-wire proof in
`tests/wp90-deadlines/deadlines_test.odin`.

| Field | WP | Signature evidence | Behaviour evidence | Doc |
|---|---|---|---|---|
| `max_write_time` | WP90 | the frozen `Limits` row | `tests/wp90-deadlines/deadlines_test.odin::wp90_a_stalled_write_is_aborted_at_the_deadline` (+ healthy-reader and zero controls) | `docs/operations.md` limits table; `docs/ai-context.md` |
| `max_idle_time` | WP90 | the frozen `Limits` row | `tests/wp90-deadlines/deadlines_test.odin::wp90_an_idle_keepalive_is_closed_at_the_idle_deadline` (+ active and zero controls) | `docs/operations.md` limits table; `docs/ai-context.md` |

**Rollback.** Fields on a frozen record are permanent once shipped; the safe
retreat recorded by ADR-039 is defaulting to `0` (off), never removal. The
bridge enforcement is deletable with the adapter (ADR-033 obligations).

## Amendment 29 — WP90b: the transport boundary gains the stream lifecycle

**Date: 2026-07-23. Authority: ADR-009 Amendment 1 (the private boundary may
gain a long-lived capability) and ADR-044.** **Ledger effect: none** — no
public symbol; the public stream surface waits for its evidence and freezes
at WP101.

**Dependency-manifest change, deliberate:** `web/internal/transport` now
imports `druse:web/internal/stream` (the WP88/WP89 registry — first-party,
same license, same owner) and `core:strconv` (hex chunk-size framing in the
detached-stream pump). The snapshot and this manifest were updated together.
`package web` itself imports neither; the one-way rules hold: stream imports
nothing of web or the backend, and the transport still never imports
`druse:web`.

**Rollback.** Internal wiring: removable with the WP90b adapter code and the
vendored bridge patch 22, leaving WP88/WP89 as unlinked machinery.

## Amendment 30 — WP96: the public streaming surface

**Date: 2026-07-23. Authority: the Phase-7 spec §5 concept inventory, ADR-044,
and the ADR-029 delegation. Freezes at WP101.** **Ledger effect: application
63 → 68.** 68 application + 2 test-support = 70. The five symbols are the
fewest that express open, bounded send and close (spec §5's budget was ≤8):

```
application	type	Stream :: struct {private: Stream_Handle}
application	type	Stream_Send :: enum {Sent, Full, Closed}
application	proc	stream :: proc(ctx: ^Context) -> (s: Stream, ok: bool)
application	proc	stream_send :: proc(s: Stream, data: []u8) -> Stream_Send
application	proc	stream_close :: proc(s: Stream)
```

**WHAT THEY DO.** `stream` detaches a long-lived response from the Handler's
Context (the mechanism is WP86's candidate C, private in
`web/internal/stream`, reached only through the transport boundary — the core
still names no backend or stream type). `Stream` is a stale-safe value token:
a copy held past the stream's life targets nothing and its send/close refuse.
`stream_send` enqueues bounded output from any thread, copy-on-enqueue, never
blocking (`.Full` is a refusal, not a wait). `stream_close` is idempotent.

**PAY ONLY WHEN USED (G7-8).** A Handler that never calls `stream` links none
of the pump or registry; the buffered path is byte-identical (G7-10). SSE is a
Crystal over this surface (WP97), not a core concept.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `Stream` | A | WP96 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp96-public-stream/public_stream_test.odin::wp96_a_handler_streams_from_a_worker_and_close_terminates` | `docs/ai-context.md::Response streaming` | an opaque stale-safe value token; a copy held past the stream's life targets nothing |
| `Stream_Send` | A | WP96 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp96-public-stream/public_stream_test.odin::wp96_a_handler_streams_from_a_worker_and_close_terminates` | `docs/ai-context.md::Response streaming` | closed enum {Sent, Full, Closed}; a stale token collapses to Closed |
| `stream` | A | WP96 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp96-public-stream/public_stream_test.odin::wp96_the_in_memory_transport_reports_no_connection` | `docs/ai-context.md::Response streaming` | detaches a response bound to the connection; ok=false where there is no connection |
| `stream_send` | A | WP96 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp96-public-stream/public_stream_test.odin::wp96_a_handler_streams_from_a_worker_and_close_terminates` | `docs/ai-context.md::Response streaming` | copy-on-enqueue from any thread; never blocks, Full is a refusal |
| `stream_close` | A | WP96 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp96-public-stream/public_stream_test.odin::wp96_a_handler_streams_from_a_worker_and_close_terminates` | `docs/ai-context.md::Response streaming` | idempotent; writes the terminating chunk and retires the connection |
| `Upload` | A | WP7.5-C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp7_5-c2-upload/upload_test.odin::upload_spool_buffered_quota_and_persist_compose` | `docs/ai-context.md::Upload` | a plain description {path, size} of a spooled body; carries no framework pointer (G-03); owned by the request, not this value |
| `Upload_Config` | A | WP7.5-C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp7_5-c2-upload/upload_test.odin::upload_spool_buffered_quota_and_persist_compose` | `docs/ai-context.md::Upload_Config` | the opt-in; a required dir (no silent /tmp) and zero-select §4.2 quota defaults; resolved into transport primitives at serve |
| `enable_upload` | A | WP7.5-C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp7_5-c2-upload/upload_test.odin::upload_spool_buffered_quota_and_persist_compose` | `docs/ai-context.md::enable_upload` | turns on spooled large-body ingestion; refused after serving/dispatch (WP17 ordering); off by default is the unchanged 413 |
| `upload` | A | WP7.5-C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp7_5-c2-upload/upload_test.odin::upload_spool_buffered_quota_and_persist_compose` | `docs/ai-context.md::upload` | returns the request's owned upload, or ok=false when the body was not spooled |
| `upload_persist` | A | WP7.5-C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/wp7_5-c2-upload/upload_test.odin::upload_spool_buffered_quota_and_persist_compose` | `docs/ai-context.md::upload_persist` | renames the spooled body out of the namespace; after it, teardown does not delete; keyed on the Context |

**Rollback.** These are frozen ledger once shipped; the mechanism they cover
is removable with the WP90 adapter code, but the names are a public contract
from the Phase-7 freeze onward.

## Amendment 31 — Closure H-3: `stats` and `Server_Stats`

**Date: 2026-07-24. Authority: the Production Readiness Closure (C-05 named the
write-observability gap; H-3 closes it) under the ADR-029 delegation. Freezes at
the Closure freeze.** **Ledger effect: application 73 → 75.** 75 application +
2 test-support = 77. Two symbols — the fewest that expose the send side:

```
application	proc	stats :: proc() -> Server_Stats
application	type	Server_Stats :: struct {refused_connections: int, responses_sent: int, response_bytes: i64, send_errors: int, write_deadline_aborts: int, stream_refused_full: int, stream_refused_budget: int, stream_aborted_slow: int}
```

**WHAT THEY DO.** `stats` returns eight running totals for the life of the
server (a scraper differences them), or the zero value when no server runs — the
same rule as `refused_connections`. `Server_Stats` joins the backend's four
buffered-send counters (vendored patch 28: responses sent, bytes on the wire,
send errors, write-deadline aborts) with the stream registry's three counters
(WP92, previously maintained and reachable from no public API). It is the same
argument `refused_connections` made for admission, applied to the send side that
was invisible.

**REDACTION HOLDS BY CONSTRUCTION.** Every field is an integer, so no
request-derived byte can reach an observer through it — the §3.1 property that
admits `refused_connections`, and `build/check_public_api.sh` pins that no field
is a string. It is not a metrics API: eight integers an application reads and
hands to whatever it already runs, the smallest thing that discharges the WP50
§3.5 observability obligation.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `stats` | A | Closure-H3 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/h3-server-stats/server_stats_test.odin::h3_stats_count_real_responses_and_are_zero_without_a_server` | `docs/ai-context.md::web.stats` | eight running totals; zero when no server runs; reads under one lock so the snapshot is coherent |
| `Server_Stats` | A | Closure-H3 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/h3-server-stats/server_stats_test.odin::h3_stats_count_real_responses_and_are_zero_without_a_server` | `docs/ai-context.md::Server_Stats` | a struct of eight integers; redaction by construction (no string field); joins buffered-send and stream counters |

**Rollback.** Frozen ledger once shipped; the backend counters they read are
removable with the WP90 adapter code (vendored patch 28), but the names are a
public contract from the Closure freeze onward.

## Amendment 33 — Campaign C: `Server_Stats` field replacement

**Date: 2026-07-27. Authority: the verification-campaign owner decision recorded
in `planning/decisoes-do-dono.md` (Campaign C, Option 4). Ledger effect: one
frozen struct field replaced in place — `lane_collisions: int` removed,
`handler_dwell_ns: i64` added. Symbol count unchanged (75 application + 2
test-support = 77).**

**WHY.** Dedicated accept (WP119) made handlers run synchronously on the lane
thread, so `handler_lane_enter` cannot return false and the 503-on-collision
path in `dispatch_exchange` is unreachable. `handler_dwell_ns` (total
nanoseconds inside dispatched handlers, as a running total) is the observable
replacement; the operator differences it for utilization and mean dwell, and
c05 pins that it moves with real work — its control (accumulator stubbed to
zero) goes red.

**CORRECTION (2026-07-28) — THE ORIGINAL JUSTIFICATION WAS WRONG, THE DECISION
STANDS.** This amendment first claimed `lane_collisions` "was structurally zero"
and that `tests/c05-saturation` "was red on `main` because it asserted the dead
contract". Both were re-tested on pristine `44bdcda` and are false. The counter
had TWO increment sites, and only the adapter one (`odin_http_adapter.odin`, the
lane-collision refusal) was unreachable; the ACCEPTOR's saturation refusal
(`vendor/odin-http/server.odin`, `accept_refuse_handler_saturation`) also
incremented it. Five pristine runs on a 4-vCPU host recorded
`lane_collisions` = 0, 2, 2, 0, 39 — tracking the client-observed 503s **1:1
every time** — and the old assertion `lane_collisions >= total_lane_503` held in
all five. c05 was red on `main` for the same scheduling-dependent reason it was
red after the swap: the unconditional `total_lane_503 > 0` assertion, since
fixed. So `lane_collisions` was never dead; it was MISNAMED, counting acceptor
saturation refusals under a lane-collision name. The replacement is still the
right call — a misnamed refusal count is not a saturation signal, and dwell is —
but the record must not claim a dead counter that measurement contradicts. If
the acceptor-refusal count is wanted, it returns under its own name
(`refused_saturation_total`), per the Campaign C plan.

**COMPATIBILITY.** This is a breaking change to a frozen struct: code that
read `lane_collisions` no longer compiles. Accepted under the ADR-029
delegation because the removed field reported acceptor saturation refusals
under a name that promised lane collisions — a consumer reading it for the
documented meaning was already being misled — and because the replacement
answers the question operators were told `lane_collisions` answered.

**TIMESTAMP COST — RE-MEASURED 2026-07-28. The earlier ~600 ns recording and its
explanation are both withdrawn.** The bracket is two clock reads plus one
seq-cst add. Measured on a 4-vCPU KVM host whose clocksource is `tsc`
(2M iterations each, `-o:speed`, loop overhead subtracted):

| Path | ns/call |
|---|---|
| glibc `clock_gettime` (**vDSO**) | 20.2 |
| raw `syscall(SYS_clock_gettime)` in C | 119.2 |
| Odin `time.now()` | 114.8 |
| `sync.atomic_add` alone | 6.4 |
| **full bracket (2 reads + add)** | **238.0** |

The mechanism is NOT a coarse clock and NOT shared tenancy. `core:time` calls
`core:sys/linux.clock_gettime`, which issues `syscall(SYS_clock_gettime, ...)`
directly — **Odin's stdlib never consults the vDSO**. Odin's 114.8 ns matches
the raw-syscall control (119.2), not the vDSO path (20.2), on a host where the
vDSO fast path is fully available. The Campaign C body's ~40–50 ns estimate was
arithmetically right for the mechanism it assumed (2 × 20.2) — that mechanism is
simply not the one in use. **Bare metal will therefore NOT bring this to tens of
nanoseconds**; the syscall boundary is host-independent in order of magnitude,
and the only route to vDSO cost is a clock path `core:time` does not provide.

At 250k req/s this is ~60 ms of CPU per second, about 6% of one core.

The previously cited reassurance — "the c05 suite passes with the cost in place
(2.0 s wall for 92 dispatches — under 2%)" — is also withdrawn: c05's handlers
dwell 40 ms, so 238 ns is 0.0006% of each, and that measurement **cannot detect
the bracket at all**. It was not evidence. The routing-benchmark before/after
delta the Campaign C plan required has still not been run; that obligation is
open, not discharged.

Fallback if a routing profile shows the bracket hot: derive timestamps from the
deadline sweep's per-lane clock (one read per sweep, amortized) instead of
per-request reads — noted, not implemented.

**CLOCK SOURCE (2026-07-28).** The bracket now uses `time.tick_now` /
`time.tick_since` (CLOCK_MONOTONIC_RAW), not `time.now` / `time.since`
(CLOCK_REALTIME). `time.since` returns a SIGNED difference, so an NTP step
backward during a dispatch added a negative value to a total operators read as
monotonically increasing — a differenced sample could go negative. Pinned by
`build/check_c05_controls.sh`.

| Symbol | Ledger | Campaign | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `Server_Stats` (field) | A | C | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c05-saturation` (dwell tracked under ramp; control red) | `docs/operations.md` | `lane_collisions` removed; `handler_dwell_ns` added; struct remains 9 integer fields, no string |

## Amendment 34 — acceptor saturation is transport-only and observable

**Date: 2026-07-29. Authority: owner-approved post-soak corrective plan.
Ledger effect: no symbol added; one integer field,
`saturation_refusals: int`, is added to the frozen `Server_Stats` value.**

The dedicated acceptor previously emitted a raw HTTP 503 when all Handler lanes
were active, before it had parsed or associated a request. Go `net/http`
reported those bytes as an unsolicited response on an idle channel. The
acceptor now closes the socket without HTTP and increments a dedicated running
total. `refused_connections` remains the max-connections admission budget;
`handler_dwell_ns` remains dispatched Handler time.

The behavioural evidence is non-vacuous: `tests/c05-saturation` holds four
lanes behind a barrier, drives eight additional sockets, requires eight
transport refusals, zero pre-request HTTP replies and an exact
`saturation_refusals` delta of eight. Its isolated mutant restores the raw 503
and must fail on the forbidden bytes.

Current signature:

```
application	type	Server_Stats :: struct {refused_connections: int, saturation_refusals: int, responses_sent: int, response_bytes: i64, send_errors: int, write_deadline_aborts: int, handler_dwell_ns: i64, stream_refused_full: int, stream_refused_budget: int, stream_aborted_slow: int}
```

## Amendment 32 — Corrective WP C1 (friction F8-1): `Status` gains 409/413/429/503

**Date: 2026-07-24. Authority: the Corrective Program (`planning/corrective-program-plan.md`),
owner-mandated, closing the Phase-8 friction ledger toward production readiness.**
**Ledger effect: NONE — `Status` is a single symbol already counted; the ledger
stays application 75 + test-support 2 = union 77.** This amendment WIDENS one
frozen enum's signature, additively.

`Status` gains four members, in numeric order among the existing ones:

```
Conflict            = 409
Payload_Too_Large   = 413
Too_Many_Requests   = 429
Service_Unavailable = 503
```

**WHY.** Proof-by-use (Phase 8) recorded that **three independent applications** —
the reference board, the crystals `examples/notes` app, and (for 413) the
framework's own body-too-large path — were forced to spell operationally-essential
statuses as raw-int casts (`web.Status(503)`, `web.Status(409)`), which defeats
the named-checked-value purpose of the enum and is undiscoverable. F8-1 is the
first ledger entry and the most-corroborated. These four are the codes a
production service actually returns: 409 (optimistic conflict / unique
violation), 413 (payload too large), 429 (rate limiting), 503 (readiness / pool
exhaustion / backpressure).

**ADDITIVE, no member moved.** Every existing member keeps its value; an enum
addition does not break a `case` match on the current members. The formerly
private `STATUS_BODY_TOO_LARGE :: Status(413)` cast is **removed** — the
body-too-large path now returns the named `.Payload_Too_Large`, so 413 is a
first-class member used internally too. (304, still framework-internal cache
negotiation a handler never returns, legitimately stays a private `Status(304)`.)

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `Status` (widened) | A | C1 | `build/phase1-public-signatures.txt` (the 14-member row) + `build/check_phase1_freeze.sh` (the pinned declaration) | `tests/c1-status-codes/status_codes_test.odin` (named members equal their codes and reach the wire) | `docs/ai-context.md` (the member set) | +409/413/429/503; no ledger growth; `STATUS_BODY_TOO_LARGE` removed; mutation probes 39/46 re-aimed to the inverted control |

**Rollback.** Reversible before release (remove the four members, restore the
private 413 cast) — but from the corrective freeze onward the names are a public
contract. This is the first of the C1..C7 corrective batch.

## Amendment 33 — Corrective WP C2 (frictions F8-2/F8-4): `set_header` and `bytes`

**Date: 2026-07-24. Authority: the Corrective Program, owner-mandated.**
**Ledger effect: application 75 → 77.** 77 application + 2 test-support = union
**79**. Two symbols — the smallest response-surface completion that closes two
findings at once:

```
application	proc	set_header :: proc(ctx: ^Context, name: string, value: string) -> bool
application	proc	bytes :: proc(ctx: ^Context, status: Status, content_type: string, data: []u8)
```

**WHY.** Proof-by-use (Phase 8) recorded that the public surface had **no way to
set a response header** (F8-2) — so cookie sessions, CSRF, `Cache-Control`,
`Location` and `Content-Disposition` were all inexpressible, and the board was
forced onto bearer tokens — and **no buffered binary responder** (F8-4), so a
file download (a PDF, an image, an attachment) could not be served with a chosen
media type. The two gaps are one missing region of the response surface.

**`set_header`** records an application header into request-local storage (copied,
so a handler-local string is safe) that rides on EVERY response path after the
framework headers; it returns `false` — rather than silently dropping — when the
response is committed, the name/value carries a control byte (CR/LF/NUL injection),
the name is framework/transport-owned, or the per-request budget is exhausted.
**`bytes`** is the buffered binary responder: a caller-chosen `Content-Type`
(validated for control bytes, copied to request-local storage) and a `[]u8` body
the `Response` owns and releases — `web.text`'s ownership model with an arbitrary
media type. Together they make an auth-gated file download expressible:
`set_header(ctx, "Content-Disposition", …); bytes(ctx, .OK, ct, data)`.

**REDACTION / INJECTION.** `set_header` and `bytes` both reject CR/LF/NUL in any
field, closing response-splitting by construction. Framework-owned header names
are refused so an application cannot corrupt `Content-Type`/`Content-Length`/the
transport framing. Storage is fixed request-local (no allocation, no teardown),
bounded by `APP_HEADER_MAX`/`APP_HEADER_BUFFER`/`CONTENT_TYPE_MAX`.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `set_header` | A | C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c2-response-surface/contract_test.odin::c2_set_header_rides_on_the_response` + `::c2_set_header_refuses_reserved_and_injection` | `docs/ai-context.md::web.set_header` | app header, copied to request-local storage, emitted after framework headers; rejects committed/injection/reserved/over-budget with `false` |
| `bytes` | A | C2 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c2-response-surface/contract_test.odin::c2_bytes_sends_typed_binary_body` + `::c2_bytes_rejects_control_content_type` | `docs/ai-context.md::web.bytes` | buffered binary responder; caller `Content-Type` validated + copied; body owned by the Response like `web.text` |

**Rollback.** Reversible before release; from the corrective freeze onward the two
names are a public contract. Second of the C1..C7 corrective batch.

## Amendment 34 — Corrective WP C3 (friction F8-6): `query_int_opt`

**Date: 2026-07-24. Authority: the Corrective Program, owner-mandated.**
**Ledger effect: application 77 → 78.** 78 application + 2 test-support = union
**80**. One symbol:

```
application	proc	query_int_opt :: proc(ctx: ^Context, name: string) -> (value: int, present: bool, ok: bool)
```

**WHY.** Proof-by-use (Phase 8) shipped a live bug: the board read an OPTIONAL
`?assignee=` filter with `web.query_int`, the REQUIRED reader, which commits a
`400 '<name>' is required` on absence — so every unfiltered list 400'd until the
deployment-#2 smoke test caught it. The existing trio had no member for the
common case: `query_int` fails closed on absence, and `query_int_or`'s `ok` is
`true` for both absent and present-valid, so it cannot report presence. This
reader distinguishes the three states an optional typed filter needs — ABSENT
(`present=false, ok=true`, no commit), PRESENT+valid (`present=true, ok=true`),
PRESENT+malformed (`present=false, ok=false`, a committed 400). It carries no
`#optional_ok` (ADR-002); all three results are load-bearing.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `query_int_opt` | A | C3 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c3-query-opt/contract_test.odin::c3_absent_is_present_false_ok_true` + `::c3_present_valid_carries_the_value` + `::c3_present_malformed_is_a_400` | `docs/ai-context.md::web.query_int_opt` | optional typed query reader; absent ≠ present ≠ malformed; empty value is present-but-malformed (a 400) |

**Rollback.** Reversible before release. Third of the C1..C7 corrective batch.

## Amendment 35 — Corrective WP C4 (friction F8-5): `stream_live`

**Date: 2026-07-24. Authority: the Corrective Program, owner-mandated.**
**Ledger effect: application 78 → 79.** 79 application + 2 test-support = union
**81**. One symbol:

```
application	proc	stream_live :: proc(s: Stream) -> bool
```

**WHY.** Proof-by-use (Phase 8, WP107) recorded that a stream had no
client-disconnect signal: an application learned a subscriber had left ONLY when
a `stream_send` returned `Closed`, so a notification hub could not prune a
departed idle client without publishing to it, and an idle project accumulated
dead subscribers against the open-stream cap. `stream_live` is the targeted,
reversible half the ledger named: a read-only predicate that reports whether a
stream is still open and would accept a send, so a registry can prune WITHOUT
sending. It mirrors `stream_send`'s admission guard exactly (generation match,
`.Open`, not close-requested, not draining), one layer down in the stream
registry (`internal/stream.is_live`, wrapped by the transport boundary), so a
stale/reused/closing token answers `false` just as a send would collapse to
`Closed`. On the in-memory test transport (no real connection) it is always
`false`; a `true` result is point-in-time (the peer may leave the instant after),
so a hub still prunes on a `Closed` send too — belt and suspenders.

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `stream_live` | A | C4 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c4-stream-live/stream_live_test.odin::c4_is_live_tracks_open_and_close` (registry: open→live, close/stale/out-of-range→dead) + `::c4_public_stream_live_false_for_zero_value` | `docs/ai-context.md::web.stream_live` | read-only disconnect predicate; mirrors the send admission guard; true-over-the-wire path is a socket exercise |

**Rollback.** Reversible before release. Fourth of the C1..C7 corrective batch.

## Amendment 36 — Corrective WP C6 (friction F8-7): `Expect: 100-continue` honored

**Date: 2026-07-24. Authority: the Corrective Program, owner-mandated.**
**Ledger effect: NONE — no public symbol changes.** This is a TRANSPORT BEHAVIOUR
amendment (like Amendment 26): the public signature snapshot is unchanged.

**WHAT CHANGES.** The WP9-D5 rule refused every `Expect` with **417** before
reading anything. Proof-by-use (Phase 8, deployment #2) found that this breaks
default clients: curl and python-requests add `Expect: 100-continue` for a large
upload, and the hard 417 failed exactly the spooled-upload path (`web.enable_upload`)
it exists to serve — a 5 MiB attachment got a 417 until the header was stripped.

Corrective WP C6 makes the adapter **honor `100-continue` by reading the body**:
per RFC 9110 §10.1.1 a server that will not send the interim `100 Continue` may
simply read the body, so the request proceeds and the handler runs. The vendored
`auto_expect_continue` stays **off** (it blocked waiting for a body that may never
arrive — mutation 53 still pins that), and no interim response is emitted; the
client sends its body after its short continue timeout. **Any other expectation**
the server cannot meet is still **417**, as the RFC requires.

**Evidence.** `tests/support/transport_conformance/corpus.odin` (wire corpus): the
old case *"Expect: 100-continue is refused with 417"* is re-aimed to *"Expect:
100-continue is honored — body read, handler runs (C6)"* (a real body, → 201,
handler runs), and a new case *"an unknown Expect is still refused with 417"*
preserves the 417 branch. Both run in `tests/wp9-wire` (real socket). The
`auto_expect_continue = false` control (`check_public_api.sh` 11a) and mutation 53
are unchanged. Adapter helper: `expect_is_100_continue` (allocation-free).

**Rollback.** Reversible before release (restore the unconditional 417). Fifth of
the C1..C7 corrective batch.

## Amendment 37 — Corrective WP C7 (friction F8-3): `request_state` (ADR-028 reopening)

**Date: 2026-07-24. Authority: the Corrective Program, owner-mandated.**
**Ledger effect: application 79 → 80.** 80 application + 2 test-support = union
**82**. One symbol:

```
application	proc	request_state :: proc(ctx: ^Context, $R: typeid) -> ^R
```

**THIS ONE REVERSES A STATED PRINCIPLE — flagged for the owner's release review.**
ADR-028 decided request-scoped state "does not exist, and there will not be one."
C7 reopens that on a NARROW reading and the fix is deliberately not the pattern
ADR-028 rejected: not Go's `context.WithValue`, not Rust's `http::Extensions`
(type-erased, dynamically-keyed state crossing library boundaries — which Druse
does not have). It is ONE application-declared TYPE per request, typeid-checked —
`web.state`'s `rawptr`+`typeid` discipline applied per request instead of per
application.

**WHY.** Proof-by-use (Phase 8, WP104) MEASURED the cost ADR-028 left standing:
every protected handler repeats the auth-resolve prologue because a `web.use`
middleware has nowhere to leave a typed result for the handler (friction F8-3).
`request_state` is the typed hand-off — a middleware resolves an identity and
stamps it; the handler reads it without re-querying.

**NOT AN UNTYPED BAG.** Exactly one value per request, exactly one type: the first
call zeroes a fixed request-local buffer (`REQUEST_STATE_MAX = 256`, no allocation)
and stamps `$R`; every later call asserts the same `$R`, so a handler asking for a
different type aborts on the typeid mismatch (the type confusion ADR-028 feared,
made impossible). A fresh `Context` per request (`serve_dispatch`/`test_request`)
means keep-alive never leaks one request's value into the next. `size_of(R) >
REQUEST_STATE_MAX` is a `#assert` (compile-time).

| Symbol | Ledger | WP | Signature evidence | Behaviour evidence | Doc | Notes |
|---|---|---|---|---|---|---|
| `request_state` | A | C7 | `build/phase1-public-signatures.txt` (the frozen row) | `tests/c7-request-state/request_state_test.odin::c7_request_state_flows_from_middleware_to_handler` + `::c7_request_state_does_not_leak_across_requests` + `::c7_same_type_returns_same_pointer` | `docs/ai-context.md::web.request_state` | one typed request-scoped value; typeid-checked; fixed request-local storage; ADR-028 amendment |

**Rollback.** Reversible before release (remove the proc + the Context fields;
restore the ADR-028 statement). Sixth of the C1..C7 corrective batch. **This is
the amendment the release-readiness review must ratify as a philosophy change, not
merely a gap fix — see `planning/adr-028-amendment.md`.**

---

## Amendment 38 — Audit J3/J4: `Limits.max_json_nodes`, no ledger growth

**Date: 2026-07-28. Authority: the owner, on the measurements below. Ledger
effect: none; application remains 62 and test-support remains 2.**

**Why this exists, in numbers.** Two bodies, both well-formed, both inside
`max_body`, both measured on this project's toolchain and host:

| body | shape | unbounded cost |
|---|---|---|
| 4 MiB | `[{},{},…]`, 1,398,101 empty objects, into a 288-byte DTO | **RSS peak +587.9 MB** |
| 4 MiB | one object, 322,000 distinct keys | **1.57–2.08 s of one Handler lane** |

The memory figure is a 1 ms high-water sample. A before/after delta reports
+52 MB, because the request arena resets at request end — it understates the
peak elevenfold, and the first version of that probe would have refuted J3 on
that artifact.

`max_body` is doing its job in both cases: the body really is 4 MiB. It is the
wrong dimension. Nothing else on the request path had grounds to refuse either
body, because neither is malformed.

**Shape and compile evidence.** Existing `Limits` gains `max_json_nodes: int`;
`DEFAULT_LIMITS.max_json_nodes` is `JSON_NODE_LIMIT` (100,000). The exact field
and constant shapes are compiler-derived in
`build/phase1-public-signatures.txt`. No new public name exists — additive to a
struct whose own doc comment records that "adding a field later is cheap. That
asymmetry is the entire argument for the size of this struct."

**Why one field and not two.** The backlog carried J3 and J4 as separate items
and proposed a key-count cap for J4. The measurement ruled that out: the J3
shape has 1.4M values and **zero keys**, so a key cap would not see it at all.
Counting values and object keys together is the one quantity both costs are
linear in — ~150 bytes per value of preflight tree, ~6 µs per key of CPU.
Nesting depth is a third axis and stays where it was (`JSON_NEST_DEPTH_MAX`,
against stack exhaustion), because it is a different failure.

**Why the default is ON**, unlike `max_write_time`, `max_idle_time` and
`max_response_bytes`. Those default off because a framework-chosen duration or
size would break applications shipping today. This one has no such tension:
100,000 nodes is two to three orders of magnitude above ordinary API traffic.
The boundary was measured, not asserted — 25,000 keys (50,001 nodes) is served
in 99 ms; 50,000 keys (100,001 nodes) is refused.

**Behaviour and negative evidence.** Counting is a named, allocation-free
procedure, `json_scan_structure`, folded into the depth pre-scan that already
walked the body — no additional pass — and it refuses **before** the parser
allocates, since building the tree is the cost being bounded. The count is
exact:

	values = commas + non-empty containers + 1
	keys   = colons

Counting containers rather than *non-empty* containers double-counts every
`{}`, and the J3 body is 1.4 million of them, so that error would land squarely
on the shape this bounds. `tests/wp67-json-boundary/internal` owns the
arithmetic directly, with the empty-container cases chosen for exactly that
trap; both mutations were run and both go red — disarming the cap, and dropping
the non-empty test (which reports `[{},{}]` as 5 nodes instead of 3).

**Measured after the change, same probes, same host:**

| | unbounded | with the default | |
|---|---|---|---|
| J3 `[]Big` RSS peak rise | +587.9 MB | **+19.9 MB** | 29× |
| J4 322,000 keys | 1.57 s | **50 ms** | 31× |

The unbounded column is the control run and reproduces the original figures to
within 0.1 MB, which is what licenses reading the other column as an effect
rather than as drift.

**A breach is a 413** with code `body_too_complex`, not `body_too_large` and not
`invalid_json`. The client's JSON is correct, so reporting a syntax error would
send it hunting for a fault that is not there; and a client that retries by
shrinking bytes has misread a refusal about structure — it could shrink 4 MiB to
400 KiB while keeping all 322,000 keys. The envelope reports the effective node
limit as a number, like `max_body`'s.

**Zero means no limit**, following `max_response_bytes`. The test asserts the
pair: the same 120,001-node body is refused under the default and decoded with
the field at zero. A first draft used a 15,001-node body, which is *under* the
default and would have passed even if the zero were ignored.

**Rollback.** Remove the field, the constant, the `Too_Many_Nodes` issue kind
and the envelope helper; `json_scan_structure` reverts to returning depth alone.
No other public name or signature changes.

---

## Amendment 39 — Fault isolation: `web.state` returns `(^T, bool)`

**Date: 2026-07-28. Authority: the owner. Ledger effect: none; application
remains 62 and test-support remains 2. THIS IS A BREAKING CHANGE — the first in
this document that requires editing existing call sites.**

**What changed.**

	state :: proc(ctx: ^Context, $T: typeid) -> ^T                      (before)
	state :: proc(ctx: ^Context, $T: typeid) -> (value: ^T, ok: bool)   (after)

Both failure modes — no state registered, and a type other than the registered
one — used to `assert`. They now log at Error level and return `(nil, false)`.

**Why, and the reasoning is about blast radius rather than taste.** Odin has no
recoverable panic (ADR-020), so an assert aborts the process. `web.state` is
called from inside a handler, and handlers run on lanes that share a process
with every other in-flight request. One handler asking for the wrong type
therefore stopped **every request on every lane** — a fault confined to one
route taking down the whole server. The two conditions are genuine programmer
errors and the old reasoning about that was correct; what it did not weigh is
that the punishment is collective.

**The `ok` is deliberately NOT `#optional_ok`.** That would let every existing
call site compile unchanged and silently receive `nil` on the failure path,
converting a loud abort into a segfault with no message — strictly worse than
what it replaces. It is also already banned on exported procedures by this
gate's own extractor rule. A hard two-value return makes each call site
acknowledge the question, which is the migration being requested rather than a
change being smuggled in.

**No `Framework_Error` member was added, and that is the substance rather than
an omission.** `Framework_Error` means *the framework failed*. After this
change it has not: it answered the question in the return value, and an
application that ignores the answer has made an application error. Growing a
frozen public enum to describe a case the caller now owns would misclassify it.
Both refusals still log — through the same private `context.logger` path
`state_poison_nil` uses — so a caller who ignores `ok` and dereferences `nil`
still gets a sentence naming the mistake rather than a bare segfault.

**Negative evidence, and it is the strongest available argument for the
change.** `tests/wp37-public-surface` carried this comment against the
wrong-type contract:

> the half a test cannot execute — a wrong type aborts the process by design
> (ADR-020), and a test that could observe it would mean the assert was not an
> assert

That was accurate, and it meant the contract went **untested for the entire
life of the API**, pinned only by a build-time control. It is now executed:
`wp37_a_wrong_type_is_refused_and_the_server_survives` drives a wrong-type
handler over the real dispatch path, asserts the 500, and then asserts that the
NEXT request is served — a line that was unreachable before, because the runner
was gone. Reverting the type check to an assert kills it with
`Signal caught: Illegal_Instruction`, which is the control.

The companion case covers the other failure mode (`web.app()`, no state
registered at all). Both silence `context.logger` for exactly the one refusing
call and restore it immediately rather than with a `defer` — a deferred restore
leaves the nil logger installed across the assertions, and `testing.expect*`
reports through `context.logger`; that exact mistake made another suite in this
repository unable to report a failure.

**Call sites migrated:** 14 across `examples/07-app-state`,
`tests/wp99-slice`, `tests/wp37-public-surface`, `tests/wp10-doc-fixtures`,
`tests/wp91-commit-security` and `tests/support/web_blocking_lab`. The example
is the one that matters, because it teaches the pattern: it checks `ok` and
answers `web.internal_error` rather than ignoring it.

**Rollback.** Restore the single-result signature and the two asserts; revert
the call sites. The two new tests must be deleted with it — they cannot run
against an asserting implementation, which is the whole point.
