# Vendored dependency — laytan/odin-http (server root package)

This directory is a **minimal snapshot** of the root server package of
`laytan/odin-http`, used by the Druse bootstrap transport adapter
(`web/internal/transport/`) and by nothing else. No application imports it.

## Provenance

| Field | Value |
|---|---|
| Upstream | https://github.com/laytan/odin-http |
| Commit | `112c49b5bcee31308a695cc3f05d156d314a61a6` |
| Commit subject | `openssl: update bundled libraries to openssl-3.6.2 (#108)`, 2026-04-11 |
| License | MIT (`LICENSE`, Copyright (c) 2023 Laytan Laats) |
| Vendored on | 2026-07-19 |
| Toolchain verified with | `dev-2026-07-nightly:819fdc7` |

The pinned commit's root package compiles offline with:

```
odin check vendor/odin-http -no-entry-point
```

## What is included (root server package only, ~102 KiB of source)

```
allocator.odin  body.odin     cookie.odin   handlers.odin  headers.odin
http.odin       mimes.odin    request.odin  response.odin  responses.odin
routing.odin    scanner.odin  server.odin   status.odin
LICENSE         mod.pkg
```

These are exactly the root-level `.odin` files of the upstream package, plus the
MIT `LICENSE` and the package manifest `mod.pkg`. The root package imports only
`core:` and `base:` packages (no OpenSSL, no HTTP client).

One file is a **local addition, not from upstream**: `body_stream.odin`, the
streaming inbound-body reader (patch 23, BRIDGE — WP7.5-C1). Unlike every other
patch, which edits an existing upstream file, this one lives on its own so it is
deletable in a single step when `core:net/http` lands. A re-vendor re-copies the
upstream files above and PRESERVES `body_stream.odin` (re-applying its paired
`scanner.odin` compaction hook), exactly as it re-applies the other patches.

## What is deliberately OMITTED

The following upstream trees are **not** vendored, because the bootstrap server
does not need them and they would add weight, extra dependencies, or platform
binaries:

```
.git/          — version-control metadata
client/        — the HTTP client (server-only bootstrap)
openssl/       — bundled OpenSSL and its libraries
old_nbio/      — a superseded async backend
examples/      — sample programs
comparisons/   — benchmark comparisons
docs/          — generated documentation
.github/       — CI workflows
README.md, odinfmt.json, .editorconfig, .gitignore — repo tooling
```

## Local divergence record

The **canonical live ledger** is `../../planning/vendor-policy.md`; its row
count is derived by `build/check_vendor_policy.sh` and currently records 45
dispositions. The table below preserves the first 24 historical patch groups
because they explain the bootstrap server's original delta. It is a historical
subset, not the current count; later bridge patches and deletions live only in
the canonical ledger so two copied lists cannot drift again.

The first twenty-four groups were numbered 1..24 below. Five added by WP9 (transport
conformance), one each by WP45,
WP46 (ADR-031) and WP47, three by WP59's drain repair, one by WP70's multi-lane
lifecycle repair, one by WP71's Handler-capacity mapping, five security
hardening fixes from the Phase-6-freeze scan: two chunked-body process crashes
(a negative chunk size and a trailer field), a Content-Length overflow, a
bare-CR header-injection sink and an obs-fold tab that could desync a proxy —
four by WP90 (ADR-039/F9/streaming): the response write deadline with
its send-cancellation and RST abort, the idle keep-alive timeout,
accept-error tolerance, and the three detached-stream hooks;
one by WP7.5-C1 (streaming inbound body): the read-side twin of WP90's
detached-stream pump, delivering a request body one bounded window at a time;
and one (patch 24) by the C-05 saturation contract under dedicated accept —
an all-lanes-active refusal that closes the accepted socket without writing
HTTP, because the acceptor has not parsed a request and its old raw 503 reached
a Go `net/http` client as an unsolicited response.

**Ten of those first twenty-four are security-motivated**: WP9's five and the
Phase-6-freeze scan's five.
All are minimal and fix a security issue, an upstream defect,
a lifecycle defect or a capacity the server had no way to bound. Each is marked
in source with `DRUSE PATCH`, recorded below, and covered by executable
evidence that failed before it. There are no opportunistic edits.

The classification is mixed. Some patches encode Druse's deliberately
stricter framing, capacity and shutdown policy; seven fix upstream lifecycle,
parsing or keep-alive defects. The distinction is recorded per row because it
decides whether a re-vendor carries a policy or expects a fix to disappear.

| # | File | Conceptual change | Why |
|---|---|---|---|
| 1 | `body.odin` (`_body_length`) | A `Content-Length` must be one or more ASCII digits and nothing else; a negative or non-decimal value is rejected. | **REMOTE DENIAL OF SERVICE.** `strconv.parse_int` accepts `-1` and stops at the first non-digit, so `Content-Length: -1` reached `scanner.max_token_size` and tripped `scanner.odin`'s `n >= 0` assertion, **killing the server process**. `2, 2` likewise parsed as `2` and silently accepted an ambiguous framing. |
| 2 | `body.odin` (`_body_chunked`) | A chunk not terminated by CRLF is rejected instead of asserted. | **REMOTE DENIAL OF SERVICE.** `assert(len(token) == 0)` treated malformed *input* as a programming error, so a chunked body missing its trailing CRLF **killed the server process**. |
| 3 | `request.odin` (`headers_validate`) | `Content-Length` + `Transfer-Encoding` is **rejected**, not repaired. | Upstream deleted the `Content-Length` and continued. That leaves the two ends of a proxy chain disagreeing about where the body ends — the request-smuggling vector RFC 9112 §6.1 calls an unrecoverable error. |
| 4 | `http.odin` (`header_parse`) | **Any** repeated `Content-Length` is rejected, even when the values are identical. | Upstream let an exact duplicate through and then merged it via the comma rule into `2, 2`, an ambiguous framing. WP9 D2 chooses refusal over normalization: it is simpler and safer. |
| 8 | `server.odin` (`Server_Opts`, `Server`, `Server_Thread`, `on_accept`, `connection_close`) | Server-wide bounded admission: `max_connections` and `reserved_connections`. A connection past `max - reserved` is closed at accept; an atomic active count makes the budget exact across Handler lanes; refusals are counted and the TRANSITION is logged, not each event. | Without it, concurrent connections are bounded only by the OS descriptor limit. WP71 additionally proved that a lane-local count multiplies the promised limit by lane count. The reservation exists so shutdown always has slots to work in (WP40). |
| 7 | `body.odin` (`_body_length`) | A request with NO `Content-Length` sets `_body_ok = true` on its success path, instead of leaving the `false` the procedure starts with. | **KEEP-ALIVE WAS BROKEN FOR EVERY GET.** `_body_ok = false` means "a body read failed" and `response_must_close` retires the connection on it — but a request with no body returned through the success path without setting it. Measured before the patch: two sequential requests on one socket, the first answered and the second met an orderly close, with **no `Connection: close` advertised**, so a client had no way to know it was paying a TCP handshake per request while HTTP/1.1 promised persistence. |
| 6 | `server.odin` (`Server_Opts`, `Connection`, `server_deadline_sweep`, `server_date_start`, `conn_handle_req`) and `response.odin` (`clean_request_loop`) | A configurable REQUEST READ DEADLINE: `request_read_timeout`. A per-thread periodic sweep closes any connection whose current request has taken longer than that to arrive. Zero disables it, which is upstream's behaviour. | **REMOTE RESOURCE EXHAUSTION (slowloris).** The upstream read has no deadline — `scanner.odin` carries an unfinished-work comment at the recv site asking for exactly this — so a client that sends a valid prefix and stops, or trickles one byte at a time, holds a connection open indefinitely. Demonstrated against this server by `tests/wp41-fault` before the patch existed (WP41), closed by it (WP46/ADR-031). |
| 5 | `http.odin` (`Method`, `Requestline`, `requestline_parse`) | A valid but unrecognized method becomes `.Unknown` and its original token is preserved in `Requestline.method_raw`, instead of the server answering `501`. | WP9 D7: method semantics are the framework's decision. `PROPFIND` must reach the dispatcher and follow the ratified 404/405 policy; the transport must not invent a status before the core sees the request. |
| 9 | `scanner.odin` (`Scanner.pending_recv`, `scanner_scan`, `scanner_on_read`) | Preserve the outstanding receive operation until it fires or is cancelled. **BRIDGE.** | The upstream scanner discarded the only handle by which `core:nbio` can cancel a pending receive. WP58 proved that an idle keep-alive connection then made safe teardown structurally impossible. |
| 10 | `server.odin` (`connection_close`) | Cancel the scanner's outstanding receive before freeing connection-owned state. **BRIDGE.** | Without cancellation, a later completion dereferenced a freed `Connection`: WP58 reproduced an endless drain followed by `free(): invalid pointer`. This is an upstream use-after-free. |
| 11 | `server.odin` (`Server_Opts`, shutdown loop) | Apply one absolute `max_drain_time` across shutdown waits and cancel remaining reads at expiry. **BRIDGE.** | A graceful-stop knob must bound the whole operation, not only one loop. The WP58 laboratory is the executable deadline evidence. |
| 12 | `server.odin` (`Server`, `Server_Thread`, `server_shutdown`, Date cache, refusal count) | Elect one shutdown owner; make the Date cache lane-owned; atomically aggregate refusals. **BRIDGE.** | WP69 reproduced a multi-lane stop walking state another caller had begun freeing. WP70's contention corpus also owns the shared-counter and lane-cache races. |
| 13 | `server.odin` (`Server_Thread`, `on_accept`, `handler_lane_enter`, `handler_lane_leave`) | Suspend a lane's accept before its synchronous application Handler begins, preserving a raced accept rather than losing it. **BRIDGE.** | Without it, the kernel can assign a new health connection to a lane blocked in PostgreSQL while another Handler lane is free. `nbio.remove` is asynchronous, so the patch also waits for cancellation completion and preserves a connection that won the race. |
| 14 | `body.odin` (`_body_chunked.on_scan`) | A chunked chunk-size must parse to a non-negative value; `-1` and overflow-wrapped hex are rejected as an invalid size. | **REMOTE DENIAL OF SERVICE.** The same class as patch 1 in the sibling path. `strconv.parse_int` accepts `-1` and wraps overflow, and the chunked decoder had no guard, so a negative size reached `scanner.max_token_size` and tripped `scanner.odin`'s `n >= 0` assertion, **killing the server process** — even for handlers that ignore the body, because the response path drains it. |
| 15 | `body.odin` (`_body_chunked.on_scan_trailer`) | Clear `headers.readonly` around trailer-field parsing, restoring it afterwards, so a trailer does not mutate the frozen header map under assertion. | **REMOTE DENIAL OF SERVICE on legal HTTP/1.1.** The server freezes request headers before dispatch, but a chunked body's trailer section is parsed after the freeze; the first trailer field reached `header_parse` → `assert(!h.readonly)` and **killed the process**. Trailers are legal, so even benign clients could trigger it. |
| 16 | `body.odin` (`_body_length`) | A `Content-Length` with more than 19 significant digits is rejected. | **REQUEST SMUGGLING (desync).** `_is_plain_decimal` permits an arbitrarily long digit string and `strconv.parse_int` wraps overflow, so a value `>= 2^64` wrapped to a small positive: the server read fewer bytes than declared and parsed the remainder as a second request. Patch 1's negative/non-decimal guard on the same field did not bound magnitude. |
| 17 | `http.odin` (`write_escaped_newlines`) | Escape a bare carriage return as `\r`, not only the line feed. | **HEADER INJECTION.** This is the only sanitization point before header values and cookie fields reach the socket; escaping only `\n` let a lone `\r` through, and a CR-tolerant downstream parser can treat it as a line terminator to confuse or split headers. |
| 18 | `http.odin` (`header_parse`) | Reject a header line beginning with a horizontal tab, like one beginning with a space. | **REQUEST SMUGGLING.** RFC 7230 obs-fold is CRLF then a space **or** a tab; the guard caught only the space, so a tab-prefixed continuation parsed as its own header here while an obs-fold-normalizing proxy merged it into the previous value — the two ends disagree on the header set. |
| 19 | `server.odin`, `response.odin` | The response write deadline (`Server_Opts.response_write_timeout`): `Connection.send_started`/`pending_send` stamped on the send path, a write branch in the deadline sweep, cancellation of the outstanding send on every close, and `connection_abort` (SO_LINGER 0 → RST) as the enforcement. | **RESOURCE EXHAUSTION + MEMORY SAFETY.** A client that stops reading parks the response, the connection and its buffers indefinitely — the write-side slowloris. The abort is RST because a graceful close flushes kernel buffers to the slow reader first, hiding the close (the measured Phase-6.5 failure). The send cancel is Patch 10's memory-safety argument on the write side: teardown frees the `Connection` an outstanding send completion still points at. |
| 20 | `server.odin`, `response.odin` | The idle keep-alive timeout (`Server_Opts.idle_timeout`): `Connection.idle_since` stamped when a keep-alive goes idle, cleared when the next request's bytes arrive, an idle branch in the sweep closing gracefully. | **RESOURCE ECONOMY.** An idle connection holds a slot until `max_connections` or the OS reclaims it; `request_started` (Patch 6) keeps its request-arrival meaning untouched, so the two clocks bound different things. |
| 21 | `server.odin` (`on_accept`) | Tolerate transient accept errors: log, re-arm accept after a short delay, count CONSECUTIVE failures per lane and panic only past a persistence limit. | **UNAUTHENTICATED REMOTE CRASH (F9).** Upstream panics the whole process on any accept error, and `ECONNABORTED`/`EINTR` are ordinary events a peer can cause at will. The failure limit keeps a permanently dead listener fatal rather than a silent outage. |
| 22 | `response.odin` (`stream_prepare`, `stream_finish`, `stream_abort`) | Three BRIDGE hooks for the detached-stream adapter: commit status/headers with chunked framing and hand the buffered heading bytes to the adapter's owner-lane pump; end the request cycle after the terminating chunk; abort without flushing on a mid-stream error. | **BRIDGE (WP90b).** The pump, framing and registry interplay live in the adapter; the backend contributes only what is private to it (the heading writer, `clean_request_loop`, `connection_abort`). Keep-alive across a detached stream is deliberately not offered. Deletable with the adapter; the official `core:net/http` adapter must expose equivalent commit/chunk/cancel capabilities before it can replace this bridge. |
| 23 | `body_stream.odin` (new local file: `body_stream`, `scan_stream_window`, `scan_buffer_cap`) and `scanner.odin` (`Scanner.stream_compact`, `scanner_scan` compaction, `scanner_reset`) | Streaming inbound body: deliver a request body to a consumer one bounded window at a time — Content-Length windowed, chunked per-chunk — reclaiming the consumed buffer prefix so a body of any size costs one window, not its length. A synchronous non-blocking sink returns `.Continue`/`.Stop`; a `.Stop` (early refusal, quota breach, drain) halts the read by never arming the next recv. Re-applies every framing guard the buffered path earned (F3 chunk-size, WP9-D2/F10 Content-Length, WP9-D3 chunk CRLF). **BRIDGE.** | **BRIDGE (WP7.5-C1).** The read-side twin of patch 22: the large-body opt-in (`web/internal/ingest`) needs the body streamed, not materialized. The buffered `body` (body.odin) is untouched — the new path is off unless `body_stream` sets `stream_compact`. Held by the `tests/wp7_5-c1-inbound-stream` corpus (reassembly, bounded buffer, early stop, chunked, over-cap refusal). Deletable with the adapter; the official `core:net/http` adapter must expose an equivalent incremental body reader before it can replace this bridge. |
| 24 | `server.odin` (`accept_refuse_handler_saturation`, `Server.refused_saturation_total`) | All-Handler-lanes-active is refused by closing the accepted socket without writing HTTP; the distinct refusal is counted. **BRIDGE.** | The dedicated acceptor has not parsed or associated an HTTP request. Its old raw 503 reached Go `net/http` as an unsolicited response on an idle channel. The deterministic C-05 barrier requires eight transport refusals, zero pre-request HTTP replies and an exact counter delta; restoring the raw response makes the mutant red. |

Patch 5 also adds a tenth entry to `_method_strings` and makes `method_parse`
skip the new member, so the existing `for r in Method` lookup (which indexes
that array under `#no_bounds_check`) stays in bounds.

Every other line is byte-for-byte upstream.

To update to a newer upstream commit, follow every current disposition in
`../../planning/vendor-policy.md`, not merely the historical subset above, and
re-run the owning executable corpora.

A note on cost, for the record: importing this package links its one `@(init)`
procedure (`status.odin::status_strings_init`, which precomputes the HTTP
status-line strings) into any binary that transitively imports it, because Odin
roots `@(init)` procedures unconditionally. This is a toolchain trait, not a
socket/server symbol — an application that never calls `web.serve` still links
ZERO socket, listener, connection, or server-teardown symbols (measured with
`nm`; see the WP8 PR). Neutralizing that `@(init)` would trim it further but
would require another patch; WP9's five patches are all security-motivated, and
this cost is not.

## Updating

To move to a different upstream commit: re-copy the root `.odin` files, the
`LICENSE` and `mod.pkg` from a fresh checkout at the new commit, apply the live
canonical disposition ledger, update provenance, and re-run the full gate and
each owning corpus. Do not make unrelated edits to these files.
