# Security-backlog reconciliation (Hardening H-1)

**Status: LIVE GATE.** Reconciles the 14 findings of the 2026-07-22
`/claude-security` scan (against the Phase-6 freeze `e6554e5`) with the current
tree, and — the part that matters — names the **test that fails if each fix
regresses.** `build/check_security_backlog.sh` fails if a row loses its pinning
test.

---

## 0. Why this exists

The only record of the 14 findings was a session memory that predated three
phases of work and had drifted: it still described findings that Phase 6.5 and
Phase 7 (WP91, patches 21/16/17/18) had closed. A fix with no named test is a
fix that can regress in silence — the exact failure mode the Closure was called
to end, applied to security. So this WP does not re-scan; it **pins**. All 14
are fixed in the current tree; the work was writing the four tests that were
missing and recording the two that cannot be pinned at the public surface, with
the reason.

**No re-scan** (owner's decision): the guarantee is this gate going red when a
fix loses its test, not a fresh sweep.

---

## 1. The reconciliation

`✅` = fixed and pinned by a named test · `◑` = fixed, pinned indirectly, reason
stated (no clean public injection path).

<!-- h1-findings: 14 -->

| # | Finding | Fixed at | Pinning test |
|---|---|---|---|
| **F1** | JSON nesting depth stack-overflow | `web/json_decode.odin:28` (`JSON_NEST_DEPTH_MAX :: 128`), enforced `:421` | ✅ `wp68_over_deep_nesting_is_refused_before_parsing` — `tests/wp67-json-boundary/decoder/contract_test.odin` |
| **F2** | chunked trailer vs `assert(!h.readonly)` | `vendor/odin-http/body.odin:354` (clears `readonly` around the trailer parse) — patch 15 | ✅ `wp9_raw_wire_corpus` — corpus case "chunked body with a trailer field is accepted" (`tests/support/transport_conformance/corpus.odin`) |
| **F3** | negative / overflow chunk-size | `vendor/odin-http/body.odin:264` (`if !ok \|\| size < 0`) — patch 14 | ✅ `wp9_raw_wire_corpus` — corpus case "negative chunk size is rejected" |
| **F4** | `X-Forwarded-For` believed leftmost (spoof) | `web/client_address.odin:163-184` (right-to-left walk, ADR-037) | ✅ `wp48i_a_spoofed_leftmost_is_ignored_behind_a_trusted_proxy` — `tests/wp48-internal/wp48_internal_test.odin` (sends `forged, real-client, real-proxy`, asserts the forged leftmost is never returned); end-to-end twin `c06_the_forwarded_client_address_is_believed_only_from_a_trusted_hop` |
| **F5** | static response skips `secure_headers` | `web/static.odin:209-216` (WP91 flattened chain) | ✅ `wp91_secure_headers_cover_a_static_response` — `tests/wp91-commit-security/static_chain_test.odin` |
| **F6** | static mount bypasses global `use()` | `web/static.odin:209-216` (same chain) | ✅ `wp91_global_middleware_runs_for_a_static_file` + `wp91_an_auth_refusal_blocks_a_static_file` |
| **F7** | intermediate-directory symlink escape | `web/static.odin:344-353` (per-segment `os.lstat` loop) | ✅ **NEW: `wp61_a_symlink_in_an_intermediate_segment_is_refused`** — `tests/wp61-public-surface/contract_test.odin` (creates a real symlink at an intermediate segment and at the final component; both refused) |
| **F8** | JSON preflight builds full parse tree (OOM) | `web/json_decode.odin:434-436` (disposable `dynamic_arena` + `defer …_destroy`) | ◑ **no dedicated leak test** — the depth cap (F1) bounds the tree, and the test runner's leak checker over the `tests/wp67-json-boundary` preflight suite would surface an arena-cleanup regression. A direct RSS assertion belongs to the C-04-style soak, not to a unit test; recorded rather than faked. |
| **F9** | unhandled `accept()` error panics | `vendor/odin-http/server.odin:873-891` (tolerate + re-arm + failure limit) — patch 21 | ✅ `c03_a_healthy_client_survives_an_rst_flood` — `tests/c03-fault-campaign/rst_flood_test.odin` (a sustained RST flood is the accept-error generator) |
| **F10** | Content-Length u64 overflow → smuggling | `vendor/odin-http/body.odin:156-176` (rejects >19 significant digits) | ✅ `wp9_raw_wire_corpus` — corpus cases "overflowing Content-Length…" and "signed and overflowing Content-Length is rejected" |
| **F11** | preflight accepts out-of-range int, decoder truncates | `web/json_decode.odin:37` (`json_int_fits`), enforced `:256` | ✅ `wp68_out_of_range_integer_is_an_invalid_field` — `tests/wp67-json-boundary/decoder/contract_test.odin` (`{"count":999999}` into a `u8` is refused, not truncated to 63) |
| **F12** | bare CR unescaped in header / cookie | `vendor/odin-http/http.odin:408-424` (`write_escaped_newlines`, the `'\r'` case) | ◑ **no public injection path** — the sink escapes a lone `\r`, but no public API lets an application put a CR into a response header: request-side CR is rejected upstream at `request_id_acceptable` (`tests/wp23-internal`, pinned), and the framework builds its own response headers. The fix is defense-in-depth at the serialization sink; a test would need a private sink call, which the two-instance rule discourages. Recorded with the inbound pin that guards the reachable half. |
| **F13** | multipart boundary via unanchored substring | `web/multipart.odin:183` (`multipart_boundary`, true MIME-parameter parse) | ✅ **NEW: `wp63_a_decoy_boundary_in_a_quoted_parameter_is_not_used`** — `tests/wp63-public-surface/contract_test.odin` (a decoy `boundary=evil` inside a quoted value with the real `boundary=good` after; body framed with the real one, so a substring parser would find no parts) |
| **F14** | tab-prefixed obs-fold not rejected | `vendor/odin-http/http.odin:177` (`line[0] != ' ' && line[0] != '\t'`) — patch 18 | ✅ `wp9_raw_wire_corpus` — corpus case "tab obs-fold header continuation is rejected" |

**All 14 fixed. 12 pinned by a named test; 2 (F8, F12) fixed with the pin
recorded as indirect and the reason stated.**

---

## 2. The attack-lab series (F-001 … F-007), reconciled 2026-07-30

A **second, separate** series, and the reason this section exists is that it had
no ledger at all. §1 reconciles the 14 findings of the 2026-07-22
`/claude-security` scan. F-001…F-007 came from the raw-socket attack-lab
sessions of 2026-07-23 and 2026-07-28, were written up in `docs/reports/`, and
were never rowed, never pinned, never gated. Their fixes were real; their
*protection* was a report.

The numbering does not collide with §1 (`F1`…`F14` vs `F-001`…`F-007`), but the
two series overlap in substance: **F-001 is the same defect as F3**, found twice
by two methods. That is recorded rather than deduplicated — two independent
findings of one bug is information about the coverage, not a bookkeeping error.

<!-- attacklab-findings: 7 -->

| # | Finding | Severity | Status in the tree | Pinning test |
|---|---|---|---|---|
| **F-001** | negative / overflow chunk-size kills the process | HIGH (DoS) | ✅ fixed — `vendor/odin-http/body.odin:264`, patch 14 | ✅ `wp9_raw_wire_corpus` — corpus case "negative chunk size is rejected". Same defect as §1 F3 |
| **F-002** | use-after-free: deferred dispatch retains an Exchange in the freed connection arena | HIGH (CWE-416) | ✅ fixed 2026-07-23 — the `next_tick` retry was REMOVED, not made safe; the path now answers 503 + `Retry-After` while the response state is still valid (`odin_http_adapter.odin`, marker `DRUSE FIX (F-002)`) | ✅ **NEW: `build/check_c05_controls.sh`** — asserts the marker, the 503, the `Retry-After` (Closure H-4) and that the adapter has exactly ONE `next_tick_poly` site (the stream pump). All four assertions proven to go red under mutation |
| **F-003** | accept starvation / event-loop wedge under sustained lane saturation | HIGH (availability) | ✅ fixed — patch 27 bounded the accept-cancel spin, patch 28 **removed** it; the wedge is impossible by construction rather than by a bound | ✅ `build/check_c05_controls.sh` — fails if the spin returns, with the reason in the message; behavioural twin `tests/c05-saturation/saturation_test.odin` |
| **F-004** | stream pump holds a zero-copy ring slice across an async send | HIGH *if triggered* | ⊘ **never reproduced.** Filed as a design concern with the guard that appears to save it, explicitly "not as a live exploit" | n/a — there is no defect to pin. Recorded so the next reader does not re-open it as an unfixed HIGH |
| **F-005** | oversized header block dropped silently instead of answered | LOW-MED | ✅ fixed — `vendor/odin-http/server.odin:1703` answers `431 Request Header Fields Too Large` and closes | ◑ **no dedicated case.** The behaviour is on the raw-wire path where the corpus lives; a case belongs there and is not yet written. Recorded as a gap rather than claimed |
| **F-006** | cookie `Max-Age` integer overflow | LOW here | ◑ **unguarded, deliberately.** `vendor/odin-http/cookie.odin:148` still parses without a range check | n/a — the code path is the CLIENT cookie parser. Druse is a server and never runs it; the report says so and rates it LOW for that reason. It becomes real only if a future work package uses the vendored client |
| **F-007** | spool admission slot leak when `begin` fails after `admit` | LOW (CWE-772) | ✅ fixed — and NOT where the report proposed. `ingest.begin` calls `release_slot(a)` on the `os.open` failure (marker "ingest audit F2"), so every caller benefits rather than one call site. The other failure return (`!a.initialized`) cannot leak: `admit` refuses on the same guard *before* incrementing | ✅ **`tests/ingest-leak/ingest_leak_test.odin::upload_admission_survives_an_unopenable_spool`** (R2-WP06, 2026-08-03) — it does exactly what the old row said a test would need: `chmod 0500` on the spool directory mid-run, `SLOTS+2` uploads that must all fail, then the mode restored and an upload that must succeed. Mutant proven: delete `release_slot(a)` from the `os.open` failure path and it goes red with *"a 503 that never clears means `begin` kept the slot it never used"*. Refuses to run as root, because root ignores DAC and the test would pass vacuously |

**Five fixed, one never a defect, one unreachable-by-construction. Three pinned
by a named control, one (F-002) newly pinned here, three recorded as indirect
with the reason.**

### R2-WP06 review of the indirect pins, 2026-08-03

R2-WP06 asks to "revisar pins indiretos F8, F12 e F-007 contra o threat model
R2". Reviewed; two rows moved and one did not, and reading the record against the
tree is what moved them.

**F-007 → pinned by a named test.** The row said a test "would need a spool
directory made unwritable mid-run". It needed exactly that and nothing more, so
it is written. The package `tests/ingest-leak` had named F1/F2/F3 in its own
header since it was created while carrying a test for F1 only — an overclaim in a
comment, which is the quietest kind.

**F12 → its reachable half was already pinned, and the row did not say so.**
The argument is "no public API lets an application put a CR into a response
header", and that is true for a stronger reason than the row gives:
`web.set_header` rejects a value containing any control byte
(`header_field_has_control`) and requires the name to be a bare token, *before*
the escaping sink is reached at all. Both refusals are pinned on the response
side by `tests/c2-response-surface/contract_test.odin` —
`c2_set_header_refuses_reserved_and_injection` covers `"a\r\nInjected: yes"` as a
value and `"X\r\nSet-Cookie"` as a name, and
`c2_set_header_refuses_every_control_byte` sweeps the rest of the C0 range. The
row cited only the *request*-side pin (`request_id_acceptable`). **What stays
indirect is the sink itself** — `write_escaped_newlines`' defence-in-depth behind
a check that already refuses — and that is the half a test would have to reach
privately. Downgrading the whole row to "no test" understated the coverage;
upgrading it to "pinned" would overstate it. Both halves are now named.

**F8 → unchanged, and the reason is still the right one.** The finding is a
memory-shape property under a hostile body: a unit test asserting "no OOM" is a
soak, and the R2 threat model does not change that. What the R2 work *does* add
is the place to assert it — `ops/soak/CRITERIA.md` 7 and 9 already bound RSS tail
slope and set a hard stop, and the JSON encode/decode workloads run for the whole
campaign. The honest statement is that F8's assertion belongs to R2-WP04's
twelve-hour run and that run has not passed yet, so the row stays `◑` rather than
borrowing credit from a campaign still in its ladder.

**The gap this section closes.** F-002's fix was validated "ad-hoc, ASan+debug
build" — 20 manual rounds — and then carried no test for a week. §0 of this
document states the rule it was violating: *a fix with no named test is a fix
that can regress in silence.* The control added on 2026-07-30 is that test.

**The gap it does NOT close.** F-005 has no raw-wire corpus case. It is written
down here rather than quietly counted as pinned, because the whole point of a
reconciliation is that the unpinned rows are visible.


---

## 2. What H-1 added

Two tests, both through the ordinary request path so a regression is caught
where a user would meet it:

- **F7** — `tests/wp61-public-surface`: a symlink at an intermediate segment
  (and at the final component) is refused. The static suite previously exercised
  only textual traversal and the final-component check; the `lstat` loop over
  intermediate segments was unpinned.
- **F13** — `tests/wp63-public-surface`: a decoy `boundary=` inside a quoted
  parameter is not used. The `multipart_boundary` MIME-parameter parser was
  referenced only by its own source.

---

## 3. The two honest gaps, and why they are not "TODO tests"

- **F8** is a memory-shape property. A unit test asserting "no OOM" is a soak,
  not an assertion, and C-04 already owns the soak instrument; the depth cap
  (F1, pinned) is what makes the tree finite in the first place.
- **F12** has no reachable trigger from the public API. Pinning a fix to a defect
  no public path can reach would mean calling a private sink, which the WP2
  two-instance rule exists to discourage. The reachable half — inbound CR — is
  rejected and pinned at `tests/wp23-internal`.

Both are recorded here rather than left as silent "we think it's fine", which is
the whole point of the reconciliation.
