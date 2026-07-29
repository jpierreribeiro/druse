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

Out of scope, because they are documented limitations rather than defects:

- **there is no shutdown or stop.** `web.serve` blocks until the process is
  signalled. Lifecycle work is Phase 4;
- **there are no configurable timeouts** and no connection or queue limits.
  These are Phase 3 and Phase 4;
- **only one server per process is supported.** Starting a second concurrently
  is not supported and is known to misbehave; see `planning/post-phase1-audit.md`
  finding A-4;
- **no TLS.** Run Druse behind a reverse proxy that terminates TLS;
- **no trusted-proxy handling.** Druse does not read `Forwarded` or
  `X-Forwarded-For`, so it cannot be tricked by them — but it also cannot tell
  you the original client address. Phase 4, ADR-013;
- panics abort the process. Odin has no recoverable panic; see
  `planning/phase-2-plan.md` FINDING-A.

A report that Druse is unsuitable for direct exposure to the public internet
is not a vulnerability — the README says so already.

## Supported versions

There is no release yet, so **only the current `main` is supported.** No
backports exist and no version is designated long-term.

Druse is built against a single pinned Odin toolchain, recorded in
`odin-version.txt`. A report against a different toolchain is welcome but may be
closed as unreproducible if it depends on compiler behaviour that the pinned
version does not have.

## Vendored dependencies

Druse vendors the root server package of
[`laytan/odin-http`](https://github.com/laytan/odin-http) under `vendor/`, at a
pinned commit, with five local security patches recorded in
`vendor/odin-http/VENDOR.md`.

If the problem is in that upstream package, please tell us as well as upstream —
the vendored copy is patched independently and may need its own fix.

## What has already been found and fixed

Phase 1's transport conformance work (WP9) found and fixed two remotely
triggerable crashes and one request-smuggling vector before any release. The
raw-wire corpus that proves those fixes lives in `tests/wp9-wire/` and runs on
every build.
