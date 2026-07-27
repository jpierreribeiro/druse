# Subsystem audit: seven defects, with controls

**Date:** 2026-07-27
**Base:** `61bec774` (merge of PR #143)
**Toolchain:** pinned `dev-2026-07-nightly:819fdc7`

A six-subsystem read of the tree — transport/io_uring, HTTP framing, JSON
binding, routing/response, memory/streaming, and benchmark methodology — against
the claims of the post-#143 review. This report records what was wrong, what was
fixed, and the negative control for each fix. Every "fixed" line below was
verified by reverting the fix and observing the test go red; where no control is
recorded, none was run and the entry says so.

## Findings fixed

### 1. Upload admission slots leaked on three paths (HIGH)

`ingest.admit` reserves a bounded slot before a byte is read; `ingest.cancel`
returns it. Three routes reached neither `on_upload_done` nor `driver_cleanup`:

- **Connection dies mid-body.** `connection_close`/`connection_abort` call
  `nbio.remove` on the pending recv, so the chunk callback never fires again and
  nothing owned the spool. The deadline sweep does this at `max_request_time`,
  **30 s by default** — so any upload slower than that leaked a slot. A 1 GiB
  body under ~35 MB/s is enough, i.e. an ordinary WAN client.
- **`ingest.begin` fails to open the spool.** The spool never received its
  `admission` pointer, so `cancel` could not find the slot. A briefly unwritable
  spool directory retired `max_concurrent` slots permanently.
- **Lane refuses dispatch with 503.** `driver_cleanup` — the only caller of
  `upload_cancel` — runs after `cfg.dispatch`, which that path returns before.

Each leak is permanent: after `max_concurrent` occurrences every upload answers
503 for the life of the process.

**Fixed** by arming a connection-teardown hook in `start_upload`, releasing the
reservation in `begin`'s failure path (`ingest.release_slot`), and cancelling
explicitly at the lane-refusal site. `ingest.cancel` is idempotent, so the paths
compose without double-release.

**Control:** `tests/ingest-leak`. With the teardown hook removed, the upload
following three stalled bodies answers **503**; with it, **201**.

### 2. Integer range check bypassed by two token forms (HIGH)

The preflight refused out-of-range integers only on the `json.Integer` arm. The
same magnitudes written differently skipped it:

- `{"small":3.7}` tokenized as `json.Float`, passed the shape check, and was
  **truncated to 3** by the stdlib cast.
- `{"big":"99999999999999999999999"}` was validated only as "parses as some
  i128", never against the destination width.

Both were confirmed exploitable by control. (`{"small":1e6}` and
`{"small":"999999"}` into a `u8` were in fact caught downstream by the stdlib
decoder — the check now refuses them earlier and explicitly, but they were not
exploitable before.)

**Fixed** by range-checking `Float → Integer` (requiring an integral, finite,
in-range value) and `String → Integer` (against the destination width). A
non-finite float is now also refused inbound, which makes the numeric contract
symmetric with the encoder's NUM-001 guard — previously a six-byte `1e999` field
could drive 500s and error-log volume.

**Control:** `tests/wp67-json-boundary/decoder`, `audit_out_of_range_integer_is_
refused_in_every_token_form`. Reverting either arm turns it red.

### 3. Duplicate-key rejection had no test at all (MEDIUM)

The strict-decoder contract states duplicate keys are refused, and the
implementation delegates that entirely to the pinned stdlib parser. No test in
the tree asserted it, on a nightly pin — the guarantee was invisible to the gate
and free to vanish under a toolchain bump.

**Verified true and now pinned** for both the plain and escape-spelled
(`a`) forms.

### 4. Chunk-size parsing was lenient where Content-Length was strict (MEDIUM)

`_is_plain_decimal` guards Content-Length against signs, whitespace and
separators. Both chunked paths passed the size line straight to
`strconv.parse_int(.., 16)` and rejected only a negative result — but Odin's
numeric parsing accepts a leading `+` and ignores `_`. So `+a` and `1_0` parsed
to valid sizes here while an RFC-strict front-end rejects the line: a
Transfer-Encoding desync, which is the smuggling primitive the Content-Length
path was already hardened against.

**Fixed** with `_is_plain_hex`, applied on both the buffered and streaming paths.

### 5. Bare LF accepted as a line terminator (MEDIUM)

`scan_lines` delegated to `bufio.scan_lines`, which terminates on a bare `\n`
and merely strips an optional `\r`. The request line and every header line used
it. A front-end that frames strictly on CRLF then disagrees with this backend
about where a header — and therefore a request — ends.

**Fixed** by requiring CRLF and refusing a bare LF, a lone CR, and an
unterminated final line. The existing raw-wire corpus passes unchanged; four
cases were added for the new rejections.

### 6. `web.no_content` dropped every framework header (HIGH for CORS users)

It was the only responder that passed `nil` instead of going through
`response_headers_finish`, so a 204 carried no `Access-Control-Allow-Origin`, no
`X-Request-Id`, no secure headers, and silently discarded every `web.set_header`
pair — contradicting that procedure's documented promise. Since 204 is the
canonical success for DELETE, a browser fetch against a CORS-configured app
failed the origin check on exactly the route shape that most often answers 204.

**Fixed.** Separately, `Vary: Origin` is now emitted on every response of a
CORS-configured app, not only on ones carrying an allow-origin: without it a
shared cache may store an unadorned response and serve it to an allowed origin.

### 7. HEAD announced `content-length: 0` (MEDIUM)

The body is suppressed at `response_body_view` before the transport computes the
length, so every HEAD advertised zero. RFC 9110 §8.6 requires the length the
equivalent GET would have sent. The clients that issue HEAD do so precisely to
learn the size.

**Fixed** by carrying the suppressed length across the private boundary
(`Outbound.suppressed_body_len`) and setting the header explicitly.

**Control:** `tests/head-content-length`. Baseline answers `0` where the GET
sends `10`.

### 8. Multipart refused valid binary parts (MEDIUM)

`multipart_parse` took the FIRST `\r\n--` after a part's headers and required it
to be the delimiter, failing the whole form otherwise. Those are four ordinary
bytes: any binary part can contain them, so a PNG or zip whose content included
the sequence made `form_field` and `form_file` return `ok=false` for every field
— content-dependent, therefore intermittent and unreproducible for the user.

**Fixed** by scanning forward until the match is actually followed by the
boundary. Fail-closed is preserved: a truncated body still ends with no match.

**Control:** `tests/multipart-content`. Baseline fails all five assertions,
including delivering a zero-length file.

### 9. Transport: two races and a silent-degradation path (HIGH)

- **Lost wakeup.** The acceptor↔lane handoff is a two-flag (Dekker) handshake
  built on Release/Acquire, which does not forbid the store-then-load reordering
  that pattern turns on. A lane freeing a slot in the window between the
  acceptor's scan and its "I am parking" store could read a stale `false` while
  the acceptor had read a stale "lane full" — both miss, and the acceptor parks
  in `nbio.tick()` with **no timeout and no timer of its own** while
  `pending_accept.valid` keeps `accept_arm` from re-arming. The server then
  accepts nothing until an unrelated lane event occurs; unbounded if traffic
  pauses. **Fixed** with a seq-cst store plus a re-scan before parking, seq-cst
  on both lane-side stores and loads, and a bounded re-check tick used *only*
  while holding an unplaceable connection (an idle server still parks
  unbounded).
- **Use-after-destroy at shutdown.** `on_accept_dedicated` never checked
  `closing`, and nothing ordered "the acceptor stopped assigning" against "the
  lane released its loop". `release_thread_event_loop` destroys the operation
  pool arena, frees the MPSC buffer, closes the eventfd and zeroes the
  `Event_Loop` — all of which the acceptor reaches through `next_tick_poly`. An
  idle lane finishes shutdown in microseconds, so a connection accepted in the
  same millisecond as `web.stop()` could be allocated from a destroyed arena.
  **Fixed** with a `closing` check on the accept callback, an `accept_drained`
  gate the lanes wait on, and deferring the acceptor's own release until after
  `threads_closed` (which also closes the reverse race, where a lane wakes a
  loop the acceptor just released).
- **A dead lane looked alive.** The lane loop `break`s on a tick error without
  clearing `td.event_loop`, so `accept_choose_lane` kept selecting it: two more
  connections were queued into an MPSC nobody would drain, `queued_handoffs`
  stuck at the cap, and the lane was silently skipped forever. `EBUSY` and
  `EAGAIN` are real io_uring errnos that reach there. **Fixed** by routing a
  tick error into `server_shutdown`, as the acceptor loop already did for itself.
- **`timespec` built wrong.** `_flush_submissions` put the whole duration in
  `tv_nsec`, so any bounded tick of ≥ 1 s produced `tv_nsec ≥ 1e9` and EINVAL —
  which, per the previous item, killed the lane. Dormant only because every
  bounded tick in the tree was under a second. **Fixed** by splitting sec/nsec.

**No control was run for these four.** They are timing-dependent races and a
latent arithmetic bug; the fixes are argued from the code and validated only by
the existing suites staying green. Pinning them needs a stress harness that does
not exist yet — see "Owed".

## Found and NOT fixed

- **`lane_collisions` is dead in dedicated-accept mode.** Handlers run
  synchronously on the lane thread, so the event loop is blocked during dispatch
  and `handler_lane_enter` can essentially never return false; the adapter's
  503-on-collision path and the metric that counts it are effectively
  unreachable. `lane_collisions` now only counts acceptor-side saturation. The
  real behaviour for a keep-alive request landing on a lane stuck in a slow
  handler is silent head-of-line queueing: no 503, no metric, only latency. This
  matters because production guidance names `lane_collisions` as a metric to
  monitor. Fixing it means deciding what the metric should mean now, which is a
  design decision, not a repair.
- **The `is_valid` pass on every JSON response.** Whether `T` can produce a
  non-finite float is a property of the type, so the check could be skipped for
  float-free DTOs. It cannot be written today: the gate needs a compile-time walk
  over `T`'s fields and the pinned `base:intrinsics` resolves a field type only
  by name, with no field-type-by-index, so the recursion is not expressible. A
  runtime walk is the RTTI cache already measured and rejected (+17.8% p99). The
  cost stays, recorded at the call site rather than left implicit.
- **Benchmark reproducibility.** No `/ping` peer server is committed, no script
  pins peer worker counts or affinity, and nothing in the repository invokes
  `wrk`. The README now says so.

## Pre-existing red tests (NOT caused by these changes)

Both were confirmed by running the pristine `61bec774` tree in a separate
worktree:

- **`tests/c05-saturation`** fails: *"the ramp produced no lane 503 at all"*,
  with `lane_collisions=0`. This is the same finding as the dead metric above,
  and the suite that would have caught it is red on main.
- **`tests/wp90-deadlines`**, case `wp90_a_stalled_write_is_aborted_at_the_
  deadline`, fails both assertions.

`tests/c03-fault-campaign` could not be completed in this environment: the
pristine baseline ran for over 25 minutes without finishing, so the RST-flood
verdict is **unverified here**, on patched and baseline alike.

## Suites re-run green

`wp9-wire` (full smuggling corpus + 4 new cases), `wp67-json-boundary/decoder`
(18 existing + 3 new), `wp63-public-surface`, `wp94-multipart`, `wp7-internal`,
`wp60-internal`, `wp60-public-surface`, `c1-status-codes`, `c2-response-surface`,
`c04-response-size`, `c06-proxy-contract`, `c08-router-corpus`, `wp41-fault`,
`wp92-backpressure`, `h3-server-stats`, `wp31-public-surface`, `wp96-public-stream`,
`wp7_5-c1-inbound-stream`, `wp7_5-c2-upload`, `wp87-body-lifecycle`,
`wp87-stream-lifecycle`, `wp88-stream-registry`, `c4-stream-live`,
`c7-request-state`, `wp58-drain`, `wp95-drain`, `g76-scale-sockets`.

## A test-isolation defect worth recording

`tests/wp63-public-surface` fails under the parallel runner and passes with
`-define:ODIN_TEST_THREADS=1`, on patched and baseline alike: its captured values
are package-level globals shared by concurrently running tests. The failure is in
the harness, not the product — but it produces error messages that read like
product bugs, which cost real time during this audit.

Separately, `wp63_a_boundary_like_string_inside_content_is_safe` does not cover
the defect its name suggests: its content mentions the boundary but never
prefixes it with `\r\n--`, so the first `\r\n--` in the body is still the real
delimiter. It passes with and without finding 8's fix. `tests/multipart-content`
is the case that actually failed.

## Owed

1. A stress harness for the transport races in finding 9 — lockstep
   connect/disconnect bursts against a saturated lane pool for the lost wakeup,
   and a connect-during-stop loop for the shutdown race.
2. A decision on what `lane_collisions` should mean under dedicated accept, and
   a green `c05-saturation` afterwards.
3. `wp90-deadlines`' stalled-write case, red on main.
4. `c03-fault-campaign` on a machine where it completes.
5. Committed ping peers plus an orchestrator, before the README table is
   presented as reproducible.
