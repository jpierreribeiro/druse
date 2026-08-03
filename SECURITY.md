# Security policy

Druse parses HTTP from untrusted clients, so it has a real attack surface and
needs a real place to report problems.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub's advisory form:

<https://github.com/jpierreribeiro/druse/security/advisories/new>

If that is unavailable, open a public issue containing only the words "security
report, please contact me" and no technical detail, and you will be contacted to
arrange a private channel.

Useful reports include: the Odin toolchain version, the Druse commit, whether
`web.serve` or `web.test_request` was in use, and the smallest input that
reproduces the problem — a raw request on the wire is ideal, since the framing
layer is where the highest-severity issues have been found so far.

You will get an acknowledgement that a human has read the report. Because this
project is maintained by one person, no fix deadline is promised; you will be
told honestly what the timeline looks like.

## What counts as a vulnerability

In scope, and treated seriously:

- request smuggling, response splitting, or any framing ambiguity between
  Druse and an upstream proxy;
- crashes, hangs, or unbounded memory growth triggerable by a remote client;
- reading or writing memory outside its lifetime — a request view that outlives
  the request, a double free, a use-after-free;
- a response committed for the wrong request, or a body that does not match its
  status;
- leaking request data (paths, queries, headers, bodies, tokens) into a log, an
  error envelope, or a framework event.

Also in scope, and called out because an earlier version of this file said the
opposite:

- **client-address spoofing.** `web.trust_proxies` opts an application into
  reading `X-Forwarded-For`, and `web.client_ip` then walks that header from the
  right, stopping at the first hop that is not a trusted prefix (ADR-037). A way
  to make `client_ip` return an attacker-chosen address from an untrusted peer,
  or to walk past the trust boundary, **is a vulnerability**. Without
  `trust_proxies` the connection's peer address is used and the header is
  ignored;
- **limits that do not bound.** `web.limits` configures the request budget —
  `max_body`, `max_request_line`, `max_headers`, `max_json_nodes`,
  `max_request_time`, `max_write_time`, `max_response_bytes`, `max_idle_time`,
  `max_connections`, `reserved_conns`, `max_drain_time`, `max_handlers`. A
  remote client that exceeds one of these without being refused is in scope,
  and so is a bound that can be walked past rather than merely exceeded —
  `max_json_nodes` in particular exists because a body inside `max_body` can
  still be structurally hostile;
- **drain that does not drain.** `web.stop` begins a graceful shutdown and
  `web.is_draining` reports it. A request admitted after the drain began, or a
  readiness probe still reporting ready after `stop` returned, is in scope.

Out of scope, because they are documented limitations rather than defects:

- **deployment outside the supported profile.** Core lifecycle state supports
  up to 16 concurrent servers, but the measured R1 profile deliberately uses
  one App/listener per process. More than 16, or an unmeasured multi-server
  resource profile, is unsupported. Cross-wired routing, stats or shutdown
  between two supported servers remains a vulnerability;
- **no TLS, and there will not be.** Run Druse behind a reverse proxy that
  terminates TLS. In-process TLS would import an enormous attack surface into a
  framework whose value is a small, frozen, gate-enforced one, and the proxy
  holding the certificate is also the thing that should assert HSTS — a
  framework behind it asserting HSTS on a cleartext hop is asserting something
  it cannot know. ADR-046, and `docs/operations.md` §1;
- **no HSTS, no CSP, and no cookie API.** `web.secure_headers` emits exactly
  `nosniff`, `DENY` and `no-referrer`. A CSP not written for your application
  breaks it, and HSTS belongs to whatever terminates TLS; set both at your
  proxy. Druse sets no cookies, so there is nothing for it to mark `Secure` or
  `HttpOnly` — if you set cookies, you own their attributes. "Druse does not
  send header X" is therefore not a vulnerability;
- panics abort the process. Odin has no recoverable panic; see
  `planning/phase-2-plan.md` FINDING-A.

A report that Druse is unsuitable for direct exposure to the public internet
is not a vulnerability — `docs/operations.md` §1 says so already, and the
supported topology is a reverse proxy under a supervisor.

## Supported versions

The version and platform support policy is normative in
`docs/supported-profile.md`: only the latest tag and current `main`, no
backports or LTS branches.

Druse is built against a single pinned Odin toolchain, recorded in
`odin-version.txt`. A report against a different toolchain is welcome but may be
closed as unreproducible if it depends on compiler behaviour that the pinned
version does not have.

## Vendored dependencies

Druse vendors the root server package of
[`laytan/odin-http`](https://github.com/laytan/odin-http) under `vendor/`, at a
pinned commit. `vendor/odin-http/VENDOR.md` records provenance and
`planning/vendor-policy.md` is the canonical, gate-counted divergence ledger.

<!-- security-patch-count: 45 -->
The ledger currently carries **45 patch dispositions**. That number is checked
by `build/check_vendor_policy.sh` against the ledger itself, so this sentence
cannot drift from the tree the way it did between Phase 6 and R2 — it said
"five" for four phases.

If the problem is in that upstream package, please tell us as well as upstream —
the vendored copy is patched independently and may need its own fix.

## What has already been found and fixed

**Phase 1 (WP9), transport conformance.** Two remotely triggerable crashes and
one request-smuggling vector, before any release. The raw-wire corpus that proves
the fixes lives in `tests/wp9-wire/` and runs on every build, with a mutation
control per guard in `build/check_wp9_mutations.sh`.

**Phase 6 freeze, security scan.** Five more in the vendored transport, all
fixed: two chunked-body process crashes (a negative chunk size, and a trailer
field parsed while the header map was marked read-only), a `Content-Length`
overflow that could desync a proxy, a bare carriage return that escaped the
header-injection sanitiser, and an obs-fold horizontal tab accepted where a
space would have been rejected.

**Audits H1, H2, M4, M7, M9, T6.** Field values carrying control bytes,
absolute-form targets whose authority disagreed with `Host`, a write deadline
that fired under the wrong name and closed gracefully into a reader that had
stopped reading, and a scanner buffer retained at body size across keep-alive.
Each carries its disposition and its evidence in the ledger.

**WP123 / ADR-018 — cross-server state.** `web.stats`, `stream_send` and the
shutdown path resolved against a single global transport slot, so in a process
running more than one server they could answer about the wrong one. Server
identity is now carried in the handle. `web.stop` also moved its framework-side
drain off the caller's thread: it is documented as callable from a `SIGTERM`
handler, and a signal delivered to a thread already holding either mutex
deadlocked the process on the stop path — widest exactly when the server was
busiest.

**F-005 (R2-WP06) — an oversized header block vanished.** A header section over
`limit_headers` answered `431` when a complete line exhausted the budget, and
**closed the connection with no response and no log line** when a single line was
larger than the remaining budget. Measured at `limit_headers = 8000`: 8,032 bytes
answered 431; 8,532 bytes was silence. Two requests over the same limit received
two different protocol outcomes decided by how the bytes fell across lines, and
the client could not distinguish the close from a network fault. Fixed in patch
44; two paired corpus cases and a mutation control prove it.

**STREAM-001 — a stream truncated by the previous stream's teardown.** Not a
remote-triggerable vulnerability, recorded here because the failure was
*silent*: `200`, a clean close, frames missing off the end, and nothing in the
log from a server with both a logger and an observer installed. A recycled
registry slot let a late teardown close the stream that had taken its place.
Evidence and the regression test are in
`evidence/2026-08-03-stream-truncation-finding/`.

## What has NOT been done

Stated plainly, because a security policy that lists only successes reads as a
completeness claim:

- **No third-party audit.** Every finding above is from this project's own
  review or its own scans.
- **No fuzzing campaign against the current candidate.** R2-WP06 owns it and it
  has not run; the corpus work above is hand-written cases, not generated ones.
- **No CVE process.** There is no advisory feed, no backport branch and no
  embargo policy. Pre-1.0 means the fix lands on `main` and in the next tag.
- **The supported profile is the boundary of the claim.** Anything outside
  `docs/supported-profile.md` — a different proxy, another platform, more than
  one server per process in production — has not been reviewed and is not
  covered by anything on this page.
