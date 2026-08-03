# STREAM-001 — a detached stream is truncated silently when its lane served a recent stream

**Found while qualifying the R2 campaign host (R2-WP02). It is not a
host-qualification result and it is not this work package's to fix.**

**Severity: high, pending triage.** A streaming response loses its tail. The
status is `200`, the connection closes cleanly, the server logs nothing, and the
client cannot tell a truncated stream from a complete one.

## What happens

Request a detached stream twice in a row from the same process. The second one is
cut short.

| Arm | Server | Stream | Result |
|---|---|---|---|
| 1 | `ops/soak/smoke-server` | 10 frames × 50 ms | **10, 7, 10, 7, 10, 7** |
| 2 | same, **3 s between requests** | 10 frames × 50 ms | **10, 10, 10, 10** |
| 3 | `tests/r1-real-proxy/server` | 10 frames × 200 ms | **10, 1, 10, 1** |

`raw/reproduction.txt` is the verbatim run. The frames that go missing are the
**last** ones — `frame-1` through `frame-7` arrive, `8`, `9` and `10` never do —
so the stream is truncated, not delayed.

## Why it is not the instrument

Two servers reproduce it, written independently and differently:

- `ops/soak/smoke-server` allocates a `Stream_Job` per request and lets the
  producer thread free it (`self_cleanup`);
- `tests/r1-real-proxy/server` keeps one global job and joins the previous
  thread at the top of the next handler.

That second one **is in the gate**, and it is the fixture that produced the R1
real-proxy evidence.

The first edition of the smoke server did share a global job, and that was a real
defect — fixed before this was recorded. The behaviour survived the fix, on both
servers, which is what moved it from "my fixture" to "the framework".

## What the arms rule out

- **Not connection reuse.** Forcing `Connection: close` on every request does not
  change it — the alternation continues, merely phase-shifted (`7, 10, 7, 10`).
- **Not the proxy.** It reproduces on plain HTTP against `127.0.0.1`, with no
  Caddy in the path.
- **Not the client.** `curl -N` de-chunks and was cross-checked against a raw
  socket reader; both see the same truncation.
- **Not load.** The host is idle — load average 0.00, one request at a time.

## What it points at

**Time, per lane.** Three seconds of idle between requests makes it disappear
entirely (arm 2). The same requests back to back reproduce it every second
request (arms 1 and 3).

That is the signature of a deadline or timer that is scoped to the lane rather
than to the request — a stream landing on a lane that recently served one appears
to inherit part of the elapsed budget and is cut when the remainder runs out.
Arm 3 supports it from the other side: that server's stream is four times longer
in wall time (2 s versus 0.5 s) and loses far more of it (9 frames of 10 versus
3 of 10).

**This is a hypothesis from black-box behaviour, not a diagnosis.** Nothing in
`web/stream.odin` or the transport was read for this. Confirming it means finding
the timer and proving the mechanism, and that is the first task of whoever picks
this up.

## Why the silence is the worse half

`server_stderr_bytes=0`. The smoke server installs **both** a console logger and
a `web.observe` observer, deliberately and for exactly this reason — and neither
produced a line while three frames were dropped and the response was closed with
`200`.

An application streaming to a browser cannot detect this. There is no error
status, no reset, no counter, and no log. Under production traffic, lanes are
reused constantly, so the idle gap that hides it in a test would rarely exist.

## What this does NOT establish

- **No root cause.** The lane-timer reading is inference from three arms, and the
  code has not been read.
- **No blast radius.** Whether this affects `web.stream` only, or any long-lived
  response, or SSE only, is unknown. Buffered responses were not tested.
- **No claim about R1's evidence.** `tests/r1-real-proxy/server` reproduces it,
  and that fixture produced the R1 real-proxy campaign — but whether that
  campaign's specific assertions would have caught or been affected by this has
  not been checked, and asserting either way without checking is what this
  programme exists to prevent.
- **Nothing about the soak.** `ops/soak/soak-server` serves no stream route, so
  R2-WP04 as pre-registered does not exercise this path at all.
- **No fix.** None was attempted.

## Suggested next step

Read the deadline handling in the stream and lane teardown paths against arm 2's
result: the cure is idle time, so whatever is not being reset between requests on
a lane is the thing to find. A regression test belongs in `tests/`, driven by two
back-to-back streams, asserting the **frame count**, because the status code
cannot see this.
