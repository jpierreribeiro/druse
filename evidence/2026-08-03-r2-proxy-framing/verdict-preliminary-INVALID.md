# R2-WP06 — framing through the real proxy: PRELIMINARY, and the harness is wrong

**Decision: INCONCLUSIVE. The comparison ran, produced a signal worth chasing,
and is INVALID as evidence because the origin server does not serve the routes
the corpus targets.**

Recorded rather than discarded, and recorded as invalid rather than quietly
fixed, because the run cost real time and the next person needs to know both
what it suggested and why it cannot be cited.

## What was built

`ops/verification/run-proxy-framing.sh` plus `proxy_framing_compare.py`. They
replay the raw-wire corpus twice — straight at Druse, and through the pinned
Caddy over TLS — and print both outcomes side by side.

The question is the one `tests/wp9-wire` cannot ask. That suite proves Druse
refuses each malformed framing when spoken to directly. **Request smuggling is a
disagreement**, not a single parser's failure: the front hop and the back hop
read the same bytes as two different requests. `docs/supported-profile.md` makes
a reviewed proxy the supported edge, so the pair is what production runs, and
nothing here had ever put a malformed frame through the pair and compared.

## Why this run is invalid

**The corpus targets `GET /ping` and `POST /echo`. The origin used —
`tests/r1-real-proxy/server` — serves `/health`, `/ready`, `/ok`, `/whoami`,
`/body`, `/stream`.** Every case that should have reached a handler answered
`404` instead of `200`, on both legs.

That makes every outcome involving a handler uninterpretable, and it is a defect
in the harness, not a finding.

## What survived the defect, and why it is still only a signal

The framing decisions happen **before routing**, so `400` (refused by the
parser) versus `404` (parsed, routed, no such route) is a real distinction that
the wrong routes do not erase. On that reading:

| Case | direct | proxied |
|---|---|---|
| CL+TE is rejected (smuggling vector) | `400` | `404` |
| duplicate identical Content-Length | `400` | `404` |
| obs-fold header continuation | `400` | `404` |
| absolute-form whose authority **disagrees** with Host | `400` | `200` |

The pattern is the same in each: **Druse refuses the bytes when they arrive
directly, and something reaches the router when the same bytes arrive through
Caddy.** The proxy normalises the framing and forwards a request Druse accepts.

For most of these that is the proxy doing its job — a hop that repairs framing
before the backend sees it is a defence, not a hole. The last row is the one
that must be chased: `docs/supported-profile.md` and vendor patch 39 (audit H2)
make the absolute-form/Host disagreement a **400 by design**, and through the
supported edge it answered `200`.

**That is a signal, not a finding.** With the wrong routes, `200` cannot be
attributed with confidence, and it may be Caddy answering rather than Druse.

## What this does NOT establish

- **No smuggling vulnerability is claimed.** Nothing here shows a request
  crossing the pair as two different requests. The corpus's own `/smuggled`
  route — the one that would prove it — was not present on this origin either.
- **The 27-of-47 divergence count is not a defect count.** Most of it is Caddy
  refusing with its own status (`501`, `502`) where Druse refuses with `400`,
  which is two hops agreeing to refuse.
- **The `CLOSED-NO-RESPONSE` rows on the direct leg are unexplained** and may be
  the comparison client rather than the server; body-carrying cases are the ones
  affected.

## What has to happen before this is evidence

1. **An origin that serves the corpus's routes** — `/ping`, `/echo` and
   `/smuggled`. `tests/wp9-wire` has that fixture behind a private dispatch;
   it needs to become a standalone binary, or the R1 origin needs the routes.
2. **Re-run, and attribute every divergence** to Caddy or to Druse by reading
   the access log alongside the origin log, which this run captured but did not
   correlate.
3. **The absolute-form case first**, because it is the one where a documented
   `400` became a `200`.
