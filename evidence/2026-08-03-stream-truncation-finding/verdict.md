# STREAM-001 — a detached stream is killed by the PREVIOUS stream's connection teardown

**Found while qualifying the R2 campaign host (R2-WP02). Root cause located,
fixed, and under a regression test in the main gate.**

**Severity: high. Status: FIXED.** A streaming response loses its tail. The
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

## Root cause

The first reading of the arms was **time, per lane** — three seconds of idle
cures it, so something looked like an unreset budget. That was wrong, and the
thing that corrected it was making the producer record WHICH outcome it got
instead of `break`-ing on anything that is not `Sent`:

```text
[ERROR] stream_send frame-8 -> Closed (STREAM-001 probe)
```

`Closed`, not `Full`. Not a queue refusing under pressure — the stream was
already gone. Both fixtures that found this collapse `{Sent, Full, Closed}` into
"not Sent" and discard which, and that is rule 1 of
`planning/diagnosability.md` ("no discard") costing a diagnosis.

**The mechanism**, in `web/internal/transport/odin_http_adapter.odin`:

1. `runtime.links` is indexed **by registry slot**, and `stream.retire` puts the
   slot straight back on the free list — with the free list handing out the
   lowest slot first, back-to-back streams on one server get the *same* slot.
2. `stream_open` does `link^ = Stream_Link{...}` on that recycled slot, which
   resets `terminated` to **false** and installs the new stream's `tok` and
   `conn`.
3. The finished stream's connection is torn down **asynchronously**, and it still
   carried `on_teardown = stream_conn_torn_down` with `user` pointing at that
   same link.
4. A teardown landing after the next stream opened passes the `link.terminated`
   guard — the new stream reset it — and runs
   `stream.close(link.tok)` + `stream.retire(link.tok.slot)` on **the new
   stream's token**. The generation check inside `close` cannot help: the link is
   holding the new token, so the close is entirely legitimate from the
   registry's point of view.

The three-second cure fits exactly: given enough idle, the teardown lands before
the next `stream` opens, and the hook finds `terminated = true`.

## The fix

`stream_forget_teardown`, called wherever a stream releases its slot — after the
terminator is sent and on a mid-stream teardown error. A stream that has already
retired its slot un-registers the connection hook, so a later teardown cannot
reach a link that no longer belongs to it.

The hook is not removed. It exists for the **other** order — an externally
initiated end (deadline sweep, shutdown force-close, scanner error) where the
teardown arrives first and must silence the pump — and that path is untouched.

**Measured after the fix, same host, same commands** (`raw/after-fix.txt`):

| Server | Before | After |
|---|---|---|
| `ops/soak/smoke-server`, 8 requests | 10, 7, 10, 7, … | **10 × 8**, zero producer refusals |
| `tests/r1-real-proxy/server`, 6 requests | 10, 1, 10, 1, … | **10 × 6** |

## The regression test

`tests/stream001-slot-reuse/`, wired into `build/check.sh`.

It asserts the **frame count**, because nothing else can see this: every
truncated response was `HTTP/1.1 200` with a clean close. It also asserts the
producer's refusal outcome, so a future `Full` — a bounded queue refusing, a
different defect — cannot pass as this one.

It requests **six** streams rather than two. The defect alternated, so a
two-request test passes half the time by landing on the good phase; with the fix
reverted, the suite reports `[10, 10, 10, 4, 10, 10]` and names `Closed`.

## Why the silence is the worse half

`server_stderr_bytes=0`. The smoke server installs **both** a console logger and
a `web.observe` observer, deliberately and for exactly this reason — and neither
produced a line while three frames were dropped and the response was closed with
`200`.

An application streaming to a browser cannot detect this. There is no error
status, no reset, no counter, and no log. Under production traffic streams open
and close constantly, so the registry slot is recycled constantly and the idle
gap that hides it in a test would rarely exist.

## What this does NOT establish

- **No blast radius survey.** The fix addresses the teardown hook on the
  connection of a stream that already retired its slot. Whether any other holder
  of a `^Stream_Link` can outlive a slot recycle was not audited; only this one
  was found, from one symptom.
- **Buffered responses were not tested.** They do not take this path — no slot,
  no link — but that is reasoning, not a measurement.
- **No claim about R1's evidence.** `tests/r1-real-proxy/server` reproduced it,
  and that fixture produced the R1 real-proxy campaign — but whether that
  campaign's specific assertions would have caught or been affected by this has
  not been checked, and asserting either way without checking is what this
  programme exists to prevent.
- **No production exposure estimate.** Under real traffic streams are opened
  constantly and the idle gap that hid this would rarely exist, so the exposure
  is plausibly worse than the alternation suggests — but that is an inference,
  and nothing measured it.
- **Nothing about the soak.** `ops/soak/soak-server` serves no stream route, so
  R2-WP04 as pre-registered does not exercise this path at all.
- **No claim that this was the only cause of anything.** It is the cause of the
  truncation in the three arms recorded here. Nothing else was attributed to it.

## What it cost to find

The producer that discarded `Stream_Send` was in both fixtures, and it was
written that way in `tests/r1-real-proxy/server` first and copied. One line kept
the outcome instead of discarding it, and the diagnosis went from "a timer
somewhere" to a located mechanism in a single run.
