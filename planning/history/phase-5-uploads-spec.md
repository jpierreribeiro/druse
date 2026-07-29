# Phase 5 uploads spec — WP62, and the seven questions OQ-20 asked first

**Status:** SPEC, 2026-07-21, under the ADR-029 delegation.
**Decides:** whether WP63 (multipart parsing) is built this phase, and in what shape.
**Verdict: BUILD IT, NARROWED.** Multipart parsing over the in-memory body. No
temporary files, no disk, no streaming.

---

## 0. Why this document exists before any code

OQ-20 has required, since Phase 4, that seven things be answered *before* an
ownership ADR is proposed: the owner of the temporary file, cleanup, quotas,
persistence transfer, disk-full, timeout, and mid-upload disconnect.

`planning/phase-5-spec.md` §2.2 made that a gate rather than a footnote, and
fixed the failure handling in advance: **if any answer requires streaming, WP63
is declined this phase and the reason is recorded.** A package that records why
it could not be built is a criterion met; one that ships a knob that lies is not.

So this document answers the seven, and the answers turn out to be shorter than
expected — because the premise underneath four of them is false.

---

## 1. The premise that turned out to be false

OQ-20 was written expecting uploads to work the way they work in frameworks
built on a streaming server: bytes arrive, the framework spools them to a
temporary file, and the handler is handed a path. Every one of the seven
questions follows from that spool.

**Druse has no spool, and cannot acquire one without changing decisions this
phase is forbidden to touch.** The request body arrives *already whole*:

- The adapter reads the body into memory subject to `Limits.max_body`
  (4 MiB by default), and a body larger than that is answered **413 before any
  handler runs** — `transport.Inbound.over_limit`, WP8 D3.
- `web.body` decodes from those bytes into the request arena (ADR-006, ADR-012).
- There is no path on which a body reaches disk, and adding one means a
  streaming read, which means changing `Dispatch_Proc` — the one part of ADR-009
  that is conceptually frozen, and which `planning/phase-5-spec.md` §4 puts out
  of scope.

That is not a limitation this work package can route around. It is the shape of
the framework, and it decides the feature.

---

## 2. The seven answers

| # | OQ-20 asks | Answer |
|---|---|---|
| 1 | Who owns the temporary file? | **Nobody. There is no temporary file.** Parts are views over the request body, which the transport owns for the exchange. |
| 2 | Cleanup? | **Nothing to clean.** The body is transport-owned and released with the request; a part that outlives the handler is a dangling view, which is the same rule every other request-derived value already carries (G-05). |
| 3 | Quotas? | **`Limits.max_body` is the quota**, enforced before the handler. Two further bounds are added by WP63 — the number of parts and the size of one part — because a 4 MiB body can otherwise be ten thousand parts, and a parser that allocates per part turns a bounded body into an unbounded loop. |
| 4 | Persistence transfer? | **The application's, entirely.** It receives bytes and decides whether they become a file, a database row, or nothing. The framework never writes to disk, so it never has to answer where, with what permissions, or under what name. |
| 5 | Disk-full? | **Cannot arise.** Nothing is written. |
| 6 | Timeout? | **`Limits.max_request_time` already bounds it** (WP46/ADR-031): the clock covers the whole arrival of the request, body included, which is exactly what a slow upload is. Nothing new is needed. |
| 7 | Mid-upload disconnect? | **Already handled, and tested.** A truncated body never completes the request, so the handler never runs; `tests/wp41-fault/` covers the truncated and trickled cases, and the WP59 drain patch cancels the pending read rather than leaking it. |

**Four of the seven dissolve because there is no spool.** The remaining three
were already answered by limits this framework shipped in Phase 3 and Phase 4.
That is the argument for building WP63 rather than declining it: the hard
questions were not dodged, they were made unreachable by decisions already
taken.

---

## 3. What WP63 may build, and what it may not

**MAY:** a parser for `multipart/form-data` over `ctx.request.body`, returning
field values and file parts as **views** over that body, with bounds on the
number of parts and the size of each.

**MAY NOT:**

- write to disk, open a file, or name a path;
- read from a socket, or know that one exists;
- allocate per part on the parse path where a bound would do;
- consume the body in a way that contradicts ADR-012's single-consumer rule —
  multipart is *a* body consumer, in the same sense `web.body` is, and calling
  both must fail the same way calling `web.body` twice does.

**The AMEND-P5-3 constraint applies with full force:** the parser takes `[]u8`
and nothing else. When `core:net/http` replaces the adapter in January 2027, a
multipart parser that only ever saw bytes keeps working unchanged. One that had
learned where bytes came from would not.

---

## 4. The honest limitation, and where it gets written down

**Druse cannot accept an upload larger than `max_body`.** The default is
4 MiB; raising it raises the memory one request can cost, because the body is
held whole. There is no configuration that makes a 2 GB upload work, and there
will not be one before streaming exists.

This is a real gap against Gin, which spools to disk through `net/http`, and it
is the kind of gap `docs/operations.md` §3 exists to name. WP64 writes it there
in these words:

> **Uploads are bounded by `max_body` and held in memory.** A file larger than
> that is refused with 413 before your handler runs. If you need large uploads,
> terminate them at a proxy or object store and hand the application a
> reference — the framework will not spool to disk, and a version that pretended
> to would be spooling into RAM.

**A framework that says this is more useful than one that discovers it in
production.** The alternative shapes were considered and rejected: spooling to
disk requires a streaming read (out of scope, and it reopens ADR-006/012);
accepting large bodies into memory without saying so is the failure mode this
project exists to avoid.

---

## 5. Decision

**WP63 proceeds, narrowed to in-memory multipart.** OQ-20 is answered and
closes with this document; the ownership ADR it asked for is unnecessary,
because the ownership question it was asked about does not arise.

The bounds WP63 must add — part count and per-part size — are the only new
policy, and they exist because `max_body` alone bounds the *bytes* and not the
*work*: a parser that allocates once per part turns a bounded body into an
unbounded loop, which is a denial of service that passes every existing limit.
