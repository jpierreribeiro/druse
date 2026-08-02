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

If the problem is in that upstream package, please tell us as well as upstream —
the vendored copy is patched independently and may need its own fix.

## What has already been found and fixed

Phase 1's transport conformance work (WP9) found and fixed two remotely
triggerable crashes and one request-smuggling vector before any release. The
raw-wire corpus that proves those fixes lives in `tests/wp9-wire/` and runs on
every build.

The Phase-6-freeze security scan found five more in the vendored transport, all
fixed and all recorded in `vendor/odin-http/VENDOR.md`: two chunked-body
process crashes (a negative chunk size, and a trailer field parsed while the
header map was marked read-only), a `Content-Length` overflow that could desync
a proxy, a bare carriage return that escaped the header-injection sanitiser, and
an obs-fold horizontal tab accepted where a space would have been rejected.
