# Vendor maintenance policy (WP51)

**Status: ACCEPTED 2026-07-21 under the ADR-029 delegation.** Audit items A-9
and A-10.

**This package moved ahead of WP46 deliberately.** ADR-031 makes WP46 the
package that patches the vendored connection read, and **a patch that predates
the policy governing patches is how a fork starts.** So the rules come first,
and WP46 is the first work package held to them.

---

## 1. What is vendored, and the standing risk

`vendor/odin-http/` is a snapshot of the root server package of
`laytan/odin-http` at commit `112c49b` (2026-04-11), vendored 2026-07-19, MIT.
Twenty-three local patches, all security-, lifecycle- or ownership-motivated, all
marked `URUQUIM PATCH` at their site and all covered by an executable case that
failed before the patch.

**The standing risk is stated by the dependency itself.** Its README:

> *"This is beta software, confirmed to work in my own use cases but can
> certainly contain edge cases and bugs."*
>
> *"I do not hesitate to push API changes at the moment, so beware."*

419 stars, 17 open issues, 8 open pull requests, one principal maintainer
(checked 2026-07-20). That is not a criticism of the project — it is an
accurate description of what a pin against it means, and it is why ADR-033
treats the foundation as an open question rather than a settled dependency.

---

## 2. Upstream first, and what checking actually found

**Rule: every patch is offered upstream unless there is a recorded reason not
to.** Code we do not own is code we do not maintain, and a patch carried
forever is a fork with extra steps.

**But the plan may never depend on an upstream merge landing.** One maintainer's
queue is not a schedule, and re-vendoring across an API its author says moves is
work regardless of who wrote the fix.

### 2.1 The twenty-three patches, each with its upstream disposition

| # | Patch | Is it upstream's bug? | Disposition |
|---|---|---|---|
| 1 | `Content-Length` must be all ASCII digits; `-1` and `2, 2` rejected | **Yes** — a remote DoS. `strconv.parse_int` accepts `-1`, which then trips a `n >= 0` assertion and **kills the process** | **OFFER UPSTREAM.** See §2.2 — checked, and it appears still present on `main` |
| 2 | A chunk not terminated by CRLF is rejected instead of asserted | **Yes** — a remote DoS, `assert` on malformed input | **APPEARS FIXED UPSTREAM** — see §2.2 |
| 3 | `Content-Length` + `Transfer-Encoding` rejected, not repaired | **No** — a policy difference. RFC 9112 §6.1 permits refusal; upstream chose repair | **CARRY.** Uruquim's WP9 D2 is stricter on purpose |
| 4 | Any repeated `Content-Length` rejected, even if identical | **No** — same class as 3 | **CARRY** |
| 5 | Unknown method becomes `.Unknown` with `method_raw` preserved, no 501 | **No** — a framework-ownership decision (WP9 D7) | **CARRY** |
| 8 | Server-wide bounded admission: a connection past `max_connections - reserved_connections` is closed at accept; the active count is atomic across lanes | **No** — a capacity decision. Upstream is a general server and does not choose a limit; Uruquim does, because a framework that inherits the kernel's limit has a failure mode it did not choose. WP71 proved a lane-local count multiplies the public limit by lane count | **CARRY** |
| 7 | A request with no `Content-Length` reports its body read as SUCCEEDED rather than failed | **Yes** — a plain upstream defect. `_body_ok = false` means "read failed", and the no-body path returned through it without correcting the flag, so `response_must_close` retired the connection | **OFFER UPSTREAM.** It breaks keep-alive for every GET in any application, is one line, and has nothing to do with Uruquim's policies |
| 6 | A configurable request read deadline; a per-thread sweep closes connections whose request has taken too long to arrive | **Yes** — the upstream read has no deadline, and `scanner.odin` carries an unfinished-work comment asking for one at the recv site | **OFFER UPSTREAM.** It is a general slowloris defence, not a Uruquim policy, and the upstream comment is as close to an invitation as one gets |
| 9 | Preserve the `recv_poly` operation handle on the scanner | **Yes** — discarding the handle makes a pending receive structurally uncancellable | **OFFER UPSTREAM.** It is the prerequisite for safe connection teardown, independent of Uruquim policy |
| 10 | Cancel a pending receive before freeing its connection | **Yes** — otherwise completion dereferences freed connection state | **OFFER UPSTREAM.** WP58 reproduced both an endless drain and `free(): invalid pointer` from this lifecycle defect |
| 11 | Bound every drain wait by one absolute deadline | **No** — the deadline and refusal semantics are Uruquim lifecycle policy | **CARRY AS BRIDGE.** Delete when the official adapter replaces this backend |
| 12 | Make multi-lane lifecycle state exact-once or lane-owned: shutdown election, Date cache and refusal total | **Yes** — repeated shutdown walked freed lane state; the shared Date buffer and refusal increment race across lanes | **OFFER UPSTREAM AS BRIDGE.** General multi-threaded server correctness, retained locally only until the adapter transition |
| 13 | Suspend one lane's accept while its synchronous application Handler runs | **No** — upstream optimizes connection acceptance; Uruquim defines Handler capacity and liveness under blocking dependencies | **CARRY AS BRIDGE.** The official adapter must satisfy the liveness corpus, not reproduce this mechanism |
| 14 | A chunked chunk-size must be a non-negative hex value; `-1` and overflow-wrapped sizes are rejected | **Yes** — a remote DoS, the same class as patch 1 in the sibling code path. `strconv.parse_int` accepts `-1` and wraps overflow, and the chunked decoder — unlike the Content-Length path — had no guard, so the negative size tripped `scanner.odin`'s `n >= 0` assertion and **killed the process** | **OFFER UPSTREAM.** Patch 1 fixed only the Content-Length path; the chunked path carries the identical unguarded `parse_int` |
| 15 | A chunked-body trailer field must not abort the frozen header map | **Yes** — a remote DoS on legal HTTP/1.1. The server freezes request headers before dispatch, but a trailer field is parsed after the freeze and mutates the map, tripping `assert(!h.readonly)` and **killing the process** on the first trailer line | **OFFER UPSTREAM.** Trailer parsing is the decoder's own bookkeeping and must clear the freeze that exists to forbid handler mutation, as the terminating-line branch already does |
| 16 | A `Content-Length` with more than 19 significant digits is rejected | **Yes** — a request-smuggling desync. `strconv.parse_int` wraps a value `>= 2^64` to a small positive, so the server reads fewer bytes than declared and treats the remainder as a second request; the `[2^63, 2^64)` range already wrapped negative and was caught, the `>= 2^64` range was not | **OFFER UPSTREAM.** The magnitude check completes the existing negative/non-decimal guard on the same field |
| 17 | A bare carriage return in a header or cookie value is escaped, not passed through | **Yes** — a header-injection vector. `write_escaped_newlines` escaped only the line feed, so a lone `\r` reached the wire and a CR-tolerant downstream parser could treat it as a line terminator | **OFFER UPSTREAM.** The sink already escapes `\n`; escaping `\r` at the same point closes the other half |
| 18 | An obs-fold continuation line beginning with a horizontal tab is rejected, like one beginning with a space | **Yes** — a request-smuggling primitive. RFC 7230 obs-fold is CRLF then a space OR a tab; the original guard caught only the space, so a tab-prefixed line parsed as its own header here while an unfolding proxy merged it, diverging the header set | **OFFER UPSTREAM.** Completes the existing leading-space refusal to both obs-fold forms |
| 19 | The response write deadline: send-path stamps, a write branch in the sweep, cancellation of the outstanding send on every close, and an RST abort as the enforcement (WP90 / ADR-039) | **Mixed** — the missing send cancellation is upstream's use-after-free (Patch 10's twin on the write side); the deadline itself and the RST-not-graceful enforcement are Uruquim policy | **CARRY AS BRIDGE; offer the send-cancel upstream.** Delete with the adapter when `core:net/http` lands; the official adapter must expose an equivalent write deadline before it can replace this one |
| 20 | The idle keep-alive timeout: `idle_since` stamped between requests, cleared on the next request's first bytes, graceful close in the sweep (WP90 / ADR-039) | **No** — upstream simply has no idle policy; keep-alive economy is Uruquim's own operational contract | **CARRY AS BRIDGE.** Same replacement obligation as Patch 19 |
| 21 | Transient accept errors are tolerated (log, delayed re-arm, per-lane consecutive-failure limit) instead of panicking the process (WP90 / F9) | **Yes** — an unauthenticated remote crash: `ECONNABORTED` at accept is peer-triggerable weather, and upstream panics on it | **OFFER UPSTREAM.** The persistence limit is the honest part: a listener that can never accept again stays fatal rather than a silent outage |
| 22 | Detached-stream hooks: chunked heading commit, request-cycle finish after the terminator, unflushed abort (WP90b) | **No** — streaming is Uruquim's Phase-7 capability; upstream's own `Response_Writer` covers the handler-synchronous case only | **CARRY AS BRIDGE.** Deletable with the adapter; the ADR-033 replacement must pass the same wire corpus |
| 23 | Streaming inbound body: deliver a request body one bounded window at a time (Content-Length windowed, chunked per-chunk), reclaiming the consumed buffer prefix so a body of any size costs one window, not its length (WP7.5-C1) | **No** — the read-side twin of Patch 22; streaming ingestion is Uruquim's Phase-7.5 large-body capability, not a defect upstream shares (upstream materializes the whole body) | **CARRY AS BRIDGE.** Deletable with the adapter; the ADR-033 replacement must expose an equivalent incremental body reader and pass the `wp7_5-c1-inbound-stream` corpus |

| 24 | The `.Insufficient_Resources` accept retry re-arms only when the lane has no accept and is not inside a Handler — the guard the transient-error retry beside it already carried (Closure C-01 / F-C01-1) | **Yes** — an unguarded re-arm overwrites `td.accept` when the lane armed a new accept while the retry timer ran, leaving an unreachable `accept` that survives `nbio.remove(td.accept)` at shutdown and holds `num_waiting()` above zero forever. It is patch 9/10's dropped-handle defect on the accept path, reached exactly at fd exhaustion | **OFFER UPSTREAM.** The retry itself is upstream's; the missing guard makes shutdown unreachable regardless of Uruquim policy |

| 25 | A connection whose peer has already gone (orderly FIN or reset on the last `recv`) is closed at once instead of holding its admission slot for the 500 ms `Conn_Close_Delay` — but only when no response send was in flight (Closure C-03) | **Yes** — a remote liveness DoS. `active_connections` is decremented at the END of the close chain, so every RST'd connection occupies one of `max_connections - reserved_connections` slots for half a second; a flood above `budget / 500 ms` makes every later client meet the admission refusal. Measured: a healthy client was served **1 probe in 59** under a ~37,800 conn/s RST flood on unpatched code, and **56 in 56** with the patch. The linger is RFC 7230 6.6 courtesy to a client still draining a response, and there is no such client here | **OFFER UPSTREAM.** Nothing about it is Uruquim policy: upstream holds the same slot for the same delay for the same absent peer, and a plain `close` was never what flushed the response |

| 26 | The graceful-drain loop handles `.Will_Close`, the seventh `Connection_State` its `#partial switch` omitted (Closure C-03 / F-C03-1) | **Yes** — a shutdown that never ends. `.Will_Close` is entered for every request carrying `Connection: close`, every HTTP/1.0 request and every failed body read; an omitted case in a `#partial switch` is silence, so such a connection was neither closed nor logged and stayed in `td.conns`, so `len(td.conns)` never reached zero and the drain loop never broke — past every deadline, because the force-close was reachable only through the `.Active` arm. Measured: ONE client sending `Connection: close` and not reading an 8 MiB response hangs `web.stop` indefinitely; the same scenario without that header drains in 1.1 s | **OFFER UPSTREAM.** The state, the switch and the loop are all upstream's; Uruquim's drain deadline only made the omission visible by promising a bound the code could not keep |

| 27 | The wait for a cancelled `accept`'s completion inside `handler_lane_enter` is BOUNDED (250 ms); on expiry the wait is abandoned and the operation record stays detached rather than being returned to the pool (Closure C-05 / F-C05-1) | **No** — upstream has no `handler_lane_enter`; the spin arrived with Uruquim's own patch 13 (suspend a lane's accept while its synchronous Handler runs), so this is Uruquim fixing Uruquim | **CARRY AS BRIDGE.** Deletable with patch 13 when `core:net/http` lands. Measured: the unbounded form wedges **4 runs in 6** under the C-05 saturation ramp, and the wedge is total — `web.stop` did not return in 60 s against a 3 s `max_drain_time`, because a lane parked in the spin never reaches `_server_thread_shutdown` and `serve` waits for every lane |

| 28 | Write-side counters on the backend `Server` — responses sent, bytes on the wire, send errors, write-deadline aborts — incremented in `on_response_sent` and the sweep's abort branch, read by the adapter for `web.Server_Stats` (Closure H-3) | **No** — upstream has no such accounting; observability of the send side is Uruquim's operational contract, the twin of patch 12's `refused_total` on the admission side | **CARRY AS BRIDGE.** Deletable with the vendored backend when `core:net/http` lands; the official adapter must expose an equivalent, or `web.stats` loses its source |

| 29 | The two `acquire_thread_event_loop` sites (`listen`, `_server_thread_init`) DIAGNOSE a failed acquire — naming RLIMIT_MEMLOCK / memory exhaustion — instead of a bare `assert(err == nil)` with no message (Closure H-2 / F-C03-2) | **Yes** — upstream's own deferred-error-handling comment left the setup of the `io_uring` rings asserted, so a resource failure (the rings pin memory against `ulimit -l`) crashed the process at startup with a signal the test runner reported as `Segmentation_Fault`. Reproduced under ASan on a host with 8 MiB memlock and <1 GiB free | **OFFER UPSTREAM.** The graceful unwind — returning an error from `serve` rather than terminating — is the follow-up (a multi-threaded lifecycle change); this patch makes the failure ACTIONABLE, which is orthogonal to Uruquim policy |

| 30 | A server that cannot acquire its io_uring event loop UNWINDS GRACEFULLY instead of terminating: `listen` returns `net.Listen_Error.Insufficient_Resources`, a failing lane flags `init_failed` + elects shutdown (the wake loop made nil-safe) + signals the wait group, and `serve` returns the error (Closure H-2 follow-up / F-C03-2) | **Yes** — the completion of patch 29. Upstream asserted the acquire; patch 29 diagnosed it; this returns a supervisor-restartable error from `web.serve` rather than aborting the process on a startup resource shortfall | **OFFER UPSTREAM.** General server-startup robustness — a resource failure at init should be a return value, not a crash — independent of Uruquim policy |

| 31 | A `lane_collisions` counter on the backend `Server` — incremented by the adapter when `handler_lane_enter` returns false and the request is refused 503 — read by the adapter for `web.Server_Stats` (item 2) | **No** — upstream has no handler-lane model and no such accounting; exposing the framework's first saturation point (C-05: lanes ÷ dwell) is Uruquim's operational contract, the twin of patch 28's send counters on the write side | **CARRY AS BRIDGE.** Deletable with the vendored backend when `core:net/http` lands; the official adapter must expose an equivalent, or `web.stats().lane_collisions` loses its source |

| 32 | Default dedicated shared acceptor: accept on one event loop, hand each connection once to the least-loaded available Handler lane, bound pending handoffs, retain strict WP71 and skip deadline timestamps whose timeout is disabled; the old shared-accept path remains a build-time rollback | **No** — this is Uruquim's Handler-capacity/performance model, not an upstream correctness defect. It removes the request-coupled patch-13 accept cancellation and reduced `io_uring_enter` from ~5.03 to 0.160/request; the bounded handoff is required because the first form served only 19/59 healthy probes during an RST flood | **CARRY AS AN ADOPTED BRIDGE.** The owner accepted the one-box evidence and absolute p99 on 2026-07-25; the two-box/NIC run remains an explicitly documented follow-up, not silently claimed evidence. Keep the rollback flag for one release. Delete with patch 13 when the official adapter replaces this backend; evidence is the full fault/raw-wire gate and `docs/reports/2026-07-25-dedicated-accept-throughput.md` |

| 33 | Dedicated-accept lifecycle correctness (transport audit F1/F2/F3/F4/F8): the acceptor/lane availability handshake made sequentially consistent with a re-scan before parking and a bounded re-check while a connection is unplaceable; `on_accept_dedicated` refuses late CQEs once `closing` is set; lanes wait on `accept_drained` before destroying their event loops and the acceptor defers its own release until `threads_closed`; a lane tick error takes the server down instead of leaving a dead lane selectable; `nbio`'s `_flush_submissions` splits seconds from nanoseconds | **Partly** — the `timespec` split is an upstream `nbio` defect (any bounded tick of one second or more produced `tv_nsec >= 1e9` and EINVAL). The rest is correctness ON TOP OF patch 32, which is Uruquim's own model, so it cannot be offered independently of it | **CARRY WITH PATCH 32**, except the `timespec` split — **OFFER UPSTREAM** to `core:nbio`, where it is a plain arithmetic bug affecting any caller. Evidence: `docs/reports/2026-07-27-subsystem-audit-and-fixes.md`; the races themselves are argued from the code and are NOT yet pinned by a stress harness, which the report records as owed |

| 34 | Framing strictness (HTTP audit F1/F2): chunk sizes must be `1*HEXDIG` (`_is_plain_hex`) on both the buffered and streaming paths, and line termination must be CRLF — a bare LF, a lone CR, and an unterminated final line are refused | **Yes** — both are upstream leniencies with a smuggling consequence. `strconv.parse_int(.., 16)` accepts `+` and ignores `_`, so `+a`/`1_0` framed a chunk here that a strict front-end rejects; `bufio.scan_lines` terminates on a bare LF, so a proxy framing on CRLF and this backend can disagree about where a request ends. RFC 9112 §7.1 and §2.2 | **OFFER UPSTREAM.** Neither depends on Uruquim policy. Evidence is the raw-wire corpus (four cases added), never a grep over vendored text |
| 35 | Campaign C: `lane_collisions` retired, `handler_dwell_ns: i64` added to the backend `Server`; the dwell bracket is in the adapter's `dispatch_exchange`, not in the vendored code — the vendored side carries only the counter field. Under dedicated accept the 503-on-collision path is unreachable (handlers run on the lane), so the old counter was structurally zero; the dwell total is the observable replacement | **Yes** — upstream has no handler-lane model and no such accounting; same disposition as patch 31, which this supersedes | **CARRY AS BRIDGE.** Deletable with the vendored backend; `core:net/http` must expose an equivalent aggregation point, or `web.stats().handler_dwell_ns` loses its source |
| 36 | **Comment-only, `vendor/nbio/{mpsc,nbio}.odin`.** Documents the MPSC wake invariant and the two hazards of `exec` (transport audit T1): a cross-thread producer must wake the loop after its store or its item can sit stranded behind a stalled producer, and the enqueue SPINS when the target queue is full, so no caller may hold a lock across it — the deadlock recorded on `stream.try_send` | **Yes** — the invariant is upstream `nbio`'s, undocumented there, and the ring is unsound without it. No behaviour change, so it carries no risk to offer | **OFFER UPSTREAM.** Documentation of an existing upstream contract; Uruquim's own enforcement lives in `build/check_public_api.sh`, not in the vendored file |
| 37 | **Audit H3.** The transfer-coding check is a TOKEN match, not `has_suffix(enc, "chunked")`. One shared predicate `transfer_encoding_chunked_final` in `request.odin`, used by `headers_validate`, `body` and `body_stream` so the three cannot disagree about the framing of one request: `chunked` must be the final coding, appear exactly once, and match case-insensitively; empty list elements are refused | **Yes** — upstream reads `xchunked` and `chunked, chunked` as chunked (both measured returning 200 on a socket), which RFC 9112 6.1 forbids and which desynchronizes framing against any hop that disagrees. `CHUNKED` was refused, also wrong | **OFFER UPSTREAM.** A plain conformance defect in the vendored parser, independent of Uruquim policy. Evidence: `tests/support/transport_conformance/corpus.odin` (three cases, red with the predicate reverted) |
| 38 | **Audit H1.** A field line carrying a control byte is refused rather than stored: `header_line_has_control` in `http.odin`, applied at the top of `header_parse` so the line is rejected before it is lowercased, cloned or merged. Any byte below 0x20 other than HTAB, plus DEL — RFC 9110 §5.5 defines field content as `*( SP / HTAB / VCHAR / obs-text )`. HTAB stays legal OWS; obs-text (0x80–0xFF) stays legal field content | **Yes** — upstream stores them. Measured on a socket: `X-Test: a<0x00>b` and `X-Test: a<0x01>b` both answered **200**, and an application echoing the value put the 0x01 back on the wire byte-for-byte. RFC 9110 §5.5 makes rejecting or replacing CR, LF or NUL in a field value a **MUST**, calling them "invalid and dangerous, due to the varying ways that implementations might parse and interpret those characters" | **OFFER UPSTREAM.** A conformance defect in the vendored parser with no dependence on Uruquim policy. Evidence: four cases in `tests/support/transport_conformance/corpus.odin` — three red with the check reverted, and one HTAB case that must stay GREEN either way, so a rule that swept up legal OWS would be caught too |
| 39 | **Audit H2.** An absolute-form request-target whose authority disagrees with the `Host` field is refused with 400, in `on_headers_end`; `ascii_equal_fold` in `request.odin` does the comparison. Origin-form never reaches it (`url.host` is empty), and `OPTIONS *` is exempt by name — `url_parse` files the whole `*` target as the host | **Yes** — upstream never reconciles the two. Measured: `GET http://evil.example/report` with `Host: good.example` was answered **200**, and the application read `"good.example"` from `web.header(ctx, "host")`. RFC 9112 §3.2.2 makes it a **MUST** to ignore the Host field and use the target's authority; §3.2 obliges a conforming client to send them matching, so a disagreement is not an accident. One request with two identities is cache poisoning and tenant confusion against any hop that picks the other half | **OFFER UPSTREAM.** A conformance defect in the vendored server, independent of Uruquim policy. REFUSED rather than repaired, matching the CL+TE disposition: when the two agree, "use the target's authority" and "use the Host field" are the same answer, so the MUST holds by construction on everything served. Evidence: three corpus cases and two mutations in `build/check_wp9_mutations.sh` — one removing the check, one removing the `OPTIONS *` exemption |
| 40 | **Audit M4.** `conn.send_started` is stamped on EVERY response, withdrawing patch 32's default-off optimisation, and `server_deadline_sweep` gains a branch: when no `max_write_time` is configured but `max_request_time` is, a send that outlives the arrival deadline is ABORTED and counted in `write_deadline_aborts` | **Yes, and it is a diagnosis defect rather than a missing bound.** Patch 32 saved a clock syscall by stamping `send_started` only when the write deadline was on — but that field is also how the sweep tells a SENDING connection from a RECEIVING one. Measured: with the shipped defaults a client that stopped reading a 64 MiB body was cut off at `max_request_time`, logged as "request read deadline exceeded" about a request that had finished arriving, and closed GRACEFULLY — which flushes kernel buffers to the very reader that stopped reading, the outcome ADR-039 exists to prevent. The protection was real, accidental, mislabelled and terminated the wrong way | **CARRY AS BRIDGE.** The sweep and its three deadlines are Uruquim's, not upstream's, so there is nothing to offer. The behaviour is deliberately UNCHANGED in trigger and timing — same deadline, same moment — and changed only in name, counter and termination. Evidence: `wp90_a_stalled_send_without_a_write_deadline_is_a_write_abort`, which fails with the patch reverted on exactly the distinguishing signal: the body is still truncated while `write_deadline_aborts` stays at zero |
| 41 | **Audit M9.** `scanner_reset` RETURNS the connection's read buffer when it has grown past `RETAINED_BUF_MAX` (256 KiB) and nothing is pending (`s.end == 0`); the buffer allocator is captured and restored across the reallocation | **Yes.** `remove_range` moves `len` and never the backing allocation, and the buffer is sized to the request BODY (`_body_length` sets `max_token_size = ilen`) and grows by DOUBLING, so one large POST left a keep-alive connection holding a body-sized buffer with `max_idle_time` defaulting to 0 and nothing to reap it. Measured over 16 idle connections: **0.01 MB** each for 64-byte bodies, **2.02 MB** for 1 MiB, **6.49 MB** for 3 MiB — linear at ~2.1x the body, which is ~8.6 GB at `max_connections` 1024 x `max_body` 4 MiB. The patch removes 46% of it | **OFFER UPSTREAM.** A retention defect in the vendored scanner with no dependence on Uruquim policy. The threshold is above the request-line and header ceilings (8000 each) so ordinary traffic never reallocates. Evidence: `wp9_shrink_does_not_drop_a_pipelined_request`, which sends a 1 MiB body with a second request in the same write — removing the `s.end == 0` guard does not fail it, it HANGS, because the dropped request wedges the connection and the drain behind it. **HALF THE RETENTION IS UNATTRIBUTED**: ~1.17x remains, and it is neither the scanner nor the arena (`arena_free_all` keeps only the first block) |

**Sixteen of thirty-two are or contain upstream bugs; the rest are deliberate divergences.** WP70's
multi-lane lifecycle correction joins the upstream group; WP59's absolute drain
deadline joins the policy group. The bridge label changes expected lifetime,
not the evidence or upstream-offer obligation.

Previously, **four of eight were upstream bugs; four were deliberate divergences.** WP47's
admission bound joined the second group: upstream is a general-purpose server
and does not choose a connection limit, while Uruquim does — because a framework
that inherits the kernel's limit has a failure mode it did not choose.

Previously, of seven:
**four of seven were upstream bugs; three were deliberate divergences.** WP45's
keep-alive fix joined the first group and is the plainest of them: a success
path that leaves a failure flag set, breaking persistent connections for every
GET in any application built on this server.

Previously, of six:
**three of six were upstream bugs; three were deliberate divergences.** WP46's
deadline joined the first group: the upstream read path has no deadline at all
and says so in an unfinished-work comment, which makes it a gap in a
general-purpose HTTP server rather than a Uruquim-specific policy.

Originally, of five:
**two of five were upstream bugs; three were deliberate divergences.** That ratio
is the useful number: a snapshot whose patches were all policy would be cheap to
re-vendor, and one whose patches were all bug fixes would argue for upstreaming
everything. This is neither.

### 2.2 The upstream check, run 2026-07-21

Read against `laytan/odin-http` `main` — **which is ahead of the pinned commit**,
so this describes where upstream is going rather than what is vendored here:

* **Patch 2's bug appears FIXED upstream.** The chunked path now reports through
  its error callback (`s.cb(s.user_data, "", err)`) rather than asserting. So
  the patch is likely to become unnecessary at the next re-vendor.
* **Patch 1's bug appears STILL PRESENT.** `_body_length` still uses
  `strconv.parse_int` and validates only the boolean result; the subsequent
  guard is `if max_length > -1 && ilen > max_length`, which a negative `ilen`
  passes. **This one is worth reporting upstream**, because it is a remote
  process kill in a general-purpose HTTP server and not a Uruquim-specific
  concern.

**Recorded as a reading, not as a merge.** It was done from the published source
at a moment in time, and §4's re-check obligation exists because that is all it
is.

---

## 3. Patches are proven by CORPUS, never by grep over vendored source

**The rule, and it is already how the gate works.** WP16 retired the code-shape
greps that asserted patch TEXT and replaced them with executable corpus cases,
for a reason that generalises:

> **A correct re-application of a patch, written differently, must still pass.**

A grep for the patched line fails when someone re-applies the same fix with a
different variable name — which punishes the correct action. Worse, it passes
when someone preserves the line and breaks the behaviour around it.

So:

* **`tests/support/transport_conformance/corpus.odin` is the evidence for the
  five framing patches.** Each has a named case that FAILED before its patch
  existed.
* **AMENDED BY WP46, and the amendment matters.** Patch 6's evidence is NOT in
  the wire corpus — it is in `tests/wp41-fault`, because a deadline is a claim
  about TIME and the wire corpus sends bytes and reads a reply. A corpus of
  byte sequences cannot express "and then nothing happened for a while".
  **The rule is therefore an EXECUTABLE case, not specifically a corpus case**;
  the corpus is the right instrument for framing and the wrong one for
  deadlines, and pretending otherwise would have produced a case that tested
  nothing in order to satisfy a sentence.
* **The gate asserts COVERAGE, not text.** Deleting a case is caught
  statically; reverting a patch is caught by the run.
* **A new patch ships with its executable case in the same change.** A patch
  whose necessity is not demonstrated by a failing case is an opportunistic
  edit, and §5 forbids those.

---

## 4. Who watches upstream, and how often

**The obligation is on the phase gate, not on a person's memory.** Naming a
human here would be inventing a maintainer this project does not have.

* **At every phase freeze**, the vendored provenance is re-checked: is the
  pinned commit still the intended one, have any carried patches been fixed
  upstream, and has the upstream API moved in a way that would make re-vendoring
  expensive? The answers are recorded in the freeze document.
* **A carried patch that upstream has fixed is DROPPED at the next re-vendor**,
  and its corpus case stays — the case proves the behaviour, whoever implements
  it. Patch 2 is the first candidate.
* **Between freezes there is no watch, and this policy says so** rather than
  implying a vigilance nobody is performing. A dependency pinned by commit does
  not change under you; the risk of not watching is staleness, not surprise, and
  staleness is what the freeze check is for.

---

## 5. The rules a patch must satisfy

1. **Security-motivated or ownership-motivated only.** No opportunistic edits,
   no style, no "while I was in there".
2. **Marked at its site** with `URUQUIM PATCH` and the decision it implements.
3. **Covered by an EXECUTABLE case in the same change**, which failed before
   it — the raw-wire corpus for framing, the fault laboratory for anything
   about time. See §3.
4. **Listed in `vendor/odin-http/VENDOR.md`** with its conceptual change and
   its reason.
5. **Minimal.** The smallest edit that produces the behaviour, because every
   line diverged is a line to re-apply at the next re-vendor.
6. **Offered upstream, or recorded as a deliberate divergence.** §2.1's table
   gains a row.

**A patch that cannot satisfy 3 is not a patch, it is a preference.**

---

## 6. What this policy does NOT do

* **It does not decide whether to keep the dependency.** That is ADR-033, open,
  decided at WP41's evidence plus WP46's containment result. This policy governs
  patches whichever way that goes — and if Uruquim ever owns the connection
  layer, §3's corpus rule is exactly what makes the second adapter provable.
* **It does not promise upstream contribution.** §2 offers; it cannot merge.
* **It does not schedule a re-vendor.** A pin is a decision, and moving it is a
  work package with a gate run behind it, not maintenance.

---

## 8. Bridge patches — added 2026-07-21 (ADR-033 Amendment 1)

**A new patch class, and it exists because the foundation now has an expiry
date.** Odin's standard library gains an official `core:net/http` in **January
2027**. ADR-033 Amendment 1 records the consequence: owning the connection layer
is economically dead, and this project keeps patching a vendored server only
until the swap.

That makes some patches *bridges* rather than maintenance. A bridge patch:

1. **Closes a gap that is real today** and cannot wait for January.
2. **Is expected to be deleted** when the new adapter lands — not migrated, not
   ported, deleted.
3. **Is marked `URUQUIM PATCH — BRIDGE`** at its site, so a reader in 2027 knows
   the difference between a patch that carries a security fix forward and one
   that exists because the calendar did not cooperate.
4. **Is offered upstream anyway**, under §2. A bridge for this project may be a
   permanent fix for someone else's, and the rule against carrying unofferred
   patches does not relax because we plan to leave.

**The distinction matters for the wrong reason it could be abused.** "It is a
bridge" is not a licence for a rougher patch. A bridge that ships a knob which
does not bound what it claims is exactly the failure Phase 4 refused when it
withdrew `max_drain_time` — and the withdrawal, not the shipping, was the
correct call. Bridge patches meet the same bar as every other: an executable
case that failed before, a `URUQUIM PATCH` marker, and a recorded upstream
offer.

**First patches in this class:** the Phase-5 drain work (WP59) against
`vendor/odin-http/{server,scanner}.odin`. They exist because `web.stop` cannot
bound itself today, and `git diff --stat` against `vendor/` is the number that
goes into ADR-033's containment verdict.
