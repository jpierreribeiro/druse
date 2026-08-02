# C-06 — The reverse-proxy contract, as a tested topology

**Status: FAST FIXTURE RETAINED; REAL CADDY ROUND COMPLETE (C-06 + R1-WP03).**
Answers perimeter 8 of `planning/production-readiness-closure.md` §4.

---

## 0. Why a test and not another paragraph

`docs/operations.md` tells operators to run Druse behind a reverse proxy, and
the readiness matrix (C-02, rows 12 and 13) delegates **TLS** and **total
memory** to that topology by decision. The Closure's own classification rule
(§3) says what that costs:

> **Acceptable operational limitation** — explicitly delegated to another layer
> (TLS→proxy, total memory→cgroup, backlog→kernel, restart→supervisor).
> Acceptable **only if** the topology is mandatory, documented **and tested**.

Until this WP, the topology was mandatory and documented. The third word was
missing, and a delegation whose requirements are only asserted is a delegation
that discovers its own gaps in production.

---

## 1. The proxy is a fixture, and the cost of that is stated

No `nginx`, `caddy` or `haproxy` binary exists on the gate machine, and adding
one would make the gate depend on a package nobody pinned. `tests/c06-proxy-contract`
therefore carries a ~150-line relay of its own:

- **+** it runs everywhere the gate runs, forever, with no external dependency;
- **+** it can switch the one behaviour the contract turns on — response
  buffering — which an installed proxy would need a config file to change;
- **−** it is **not evidence about nginx.** It proves Druse behaves correctly
  *under the contract*; it cannot prove any particular proxy implements it.

The fast fixture is still not evidence about a product proxy. R1-WP03 closes
that distinction with Caddy 2.11.4, pinned by tag, immutable image digest and
`linux/amd64` platform in `ops/proxy/caddy/image.env`. The reviewed
topology is `ops/proxy/caddy/Caddyfile`, the repeatable campaign is
`ops/verification/run-real-proxy-contract.sh`, and the preserved
real-proxy round is `evidence/2026-08-02-r1-real-proxy/`.

---

## 2. Clause 1 — `proxy_buffering` MUST be off

The clause operators most often leave at its default, and **the default is on**
in nginx. With buffering on, a proxy reads the upstream response to completion
before forwarding a byte. A detached stream does not complete — that is what it
is for — so the client receives **nothing, ever**.

Three arms, measuring time-to-first-body-byte against a stream that emits a
chunk every 150 ms and runs for 3.0 s, with 1.2 s of patience:

| Arm | first chunk | arrived? |
|---|---|---|
| **direct** (control — no proxy) | **150.7 ms** | yes |
| **proxied, buffering OFF** (the required topology) | **150.8 ms** | yes |
| **proxied, buffering ON** (nginx's default) | — | **NO, nothing by 1.23 s** |

The control arm matters: without it a wrong number would be about the server
rather than about the topology. And the unbuffered proxy costs **0.1 ms** over
direct, so the requirement is free — the only thing it buys is not breaking.

**The inequality is the instrument.** `STREAM_CHUNKS × STREAM_TICK` must stay
comfortably above `BUFFERED_PATIENCE`, and getting that wrong is how this arm
silently stops testing anything: the first version emitted four chunks — 600 ms
of stream against 1500 ms of patience — so the stream *completed*, the buffering
proxy dutifully forwarded the whole thing at 601 ms, and the arm proved nothing.
`build/check_c06_controls.sh` checks the inequality rather than the numbers.

---

## 3. Clause 2 — the forwarded client address, believed only from a trusted hop

The proxy sets `X-Forwarded-For: 203.0.113.7`. Three arms:

| Arm | `web.client_ip` reports |
|---|---|
| through the proxy, `trust_proxies(["127.0.0.1"])` | **`203.0.113.7`** — the forwarded address |
| direct, no header | **`127.0.0.1`** — the socket peer |
| through the proxy, **no** `trust_proxies` | **`127.0.0.1`** — the header is **ignored** |

The third arm is the security half, and it is the reason this clause is in the
contract rather than in the client-address documentation: an untrusted peer that
sends the header must not be believed, or any client could name its own address
in an audit log or a rate limiter. WP48 proves the parsing; this proves the
end-to-end behaviour across a real hop, with the trust decision switched.

---

## 4. The real-proxy round

The R1 campaign adds the properties the fixture could not claim:

| Area | Executed contract |
|---|---|
| TLS/protocol | valid CA/host accepted; wrong CA/host refused; HTTP/2 client→Caddy; HTTP/1.1 Caddy→Druse |
| pool | 20 client requests with retained upstream sockets measured; four-connection maximum |
| stream | `flush_interval -1` delivers incrementally; a `response_buffers` control delivers no event inside its window |
| limits | proxy and Druse each win body/header/time arms when configured stricter; outcomes are 413/431/504 rather than ambiguous close |
| identity | edge and direct spoof fail closed; a declared multi-hop chain is walked from the right |
| degradation | admission refusal becomes one bounded 502/503 and recovers to 200 |
| shutdown | active `/ready` health plus Druse admission stop yields zero handler entries after drain is observable |
| ownership/logs | HSTS at Caddy; CSP/cookies at the app; request ID retained while header maps and secrets are deleted |

Every `reverse_proxy` block has `lb_retries 0` and
`lb_try_duration 0s`. The Go transport's narrower transparent stale-
connection behavior remains: only replay-safe requests on previously successful
pooled connections qualify. With at most four idle upstream connections, its
derived ceiling is four stale attempts plus one fresh attempt. A new TCP
refusal, which the saturation arm exercises, has one attempt.

This closes the real-proxy round for **this Caddy topology only**. Nginx,
HAProxy, a CDN in front, or materially different limits/trust networks require
their own campaign arm. The hours-long soak remains an R2 obligation, not a
proxy-contract deferral.
