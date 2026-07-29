# C-06 — The reverse-proxy contract, as a tested topology

**Status: TWO CLAUSES PROVEN, TWO OWED (Closure, WP C-06).** Answers perimeter 8
of `planning/production-readiness-closure.md` §4.

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

**A real-proxy interop round is therefore OWED**, and is recorded here beside the
phase's two other named obligations: the hours-long soak (C-04) and the 3,000
real-socket SSE round (Phase 7). All three want the same thing — a quiet machine
and a little setup — and naming them is the point, because this phase exists
because an obligation nobody wrote down stopped being trackable.

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

## 4. What is owed, named rather than implied

1. **A real-proxy round** (nginx or caddy, `proxy_buffering off`, an SSE
   endpoint, an `X-Forwarded-For` assertion). The fixture proves the contract is
   satisfiable; only a real proxy proves a real proxy satisfies it.
2. **Upstream keep-alive through a POOLING proxy** — two client requests over
   one upstream connection, in order, with no bleed. The property itself is
   already proven at the wire level by `wp41-fault`
   `phase_keep_alive_serves_two_requests_on_one_connection`; what is unproven is
   that a pooling proxy sees the same thing. It needs a fixture that pools, which
   is a second fixture rather than a switch on this one.
3. **Duplicated limits** — the proxy's timeout shorter than the server's, so the
   client sees the proxy's error while the server's connection is retired
   cleanly. Same fixture as (2).

None of the three blocks the verdict: clause 1 is the one that silently breaks a
shipped feature, and it is proven. The rest are refinements of a topology now
demonstrated to work.
