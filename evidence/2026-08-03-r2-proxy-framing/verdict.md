# R2-WP06 — the framing corpus through the real proxy

**Decision: the comparison is VALID and there is no desync between the pinned
Caddy and Druse. Nothing is promoted; the gate stays at R1.**

The earlier, invalid attempt is preserved beside this file as
`verdict-preliminary-INVALID.md`. It is not superseded quietly: it used an origin
that served none of the corpus's routes, and reading what it suggested next to
why it could not be cited is the point of keeping it.

Two questions were open. Both are answered.

## 1. Which case hit `/smuggled` — and it is not a smuggling defect

The previous run sent all 47 cases through one long-lived pair and recorded
`smuggled=1`. That number belonged to the *run*, not to any case, and a
case-by-case replay against Druse alone had already shown that none of the 47
reaches `/smuggled` through a single hop. So the hit belonged to the pair, which
is exactly where smuggling lives — and nothing said which bytes caused it.

**Isolated by replaying one case at a time against a freshly started origin,
proxy leg only** (`raw/isolation.txt`):

```text
cases_replayed=47
isolated_smuggled_total=1
isolated_smuggled_via_proxy=1
isolated_desync_hits=0
cases_with_smuggled_hit=CL+TE is rejected (smuggling vector)
cases_with_desync=none
```

**And then the count was not enough either.** A hit on `/smuggled` means "a hop
delivered a request nobody addressed" only when there is one hop. So the bytes
Caddy forwards were **recorded** rather than reasoned about, with the origin
replaced by a socket that logs verbatim (`raw/clte-upstream-forwarded.txt`,
recorder in `raw/upstream_recorder.py`):

```text
POST /echo HTTP/1.1   Host: proxy.test   Transfer-Encoding: chunked
   Via: 1.1 Caddy   X-Forwarded-For: 172.17.0.1   ...
GET /smuggled HTTP/1.1   Host: proxy.test
   Via: 1.1 Caddy   X-Forwarded-For: 172.17.0.1   ...
```

Caddy dropped the ambiguous `Content-Length: 6`, framed the first request by
`Transfer-Encoding: chunked`, and read the trailing bytes as a **pipelined second
request** — the RFC 9112 §6.1 resolution — then forwarded that second request as
its own, with its own `Via` and `X-Forwarded-For`. The two hops never disagreed.
The client sent two requests and two requests were served.

**A smuggled request cannot carry the proxy's own forwarding headers**, because
it never passed through the proxy's request path — it rode inside the first
request's body framing. That is now the instrument: `tests/support/wire_origin`
counts `smuggled` and `smuggled_via_proxy` separately, and only the difference is
a finding. Counted together, a green result and a red one looked identical.

### The finding that survives

**Druse's CL+TE refusal is unreachable in the supported topology.** The corpus
proves Druse answers 400 to CL+TE at the direct hop; behind the pinned edge Druse
never sees a CL+TE request at all, because Caddy strips the ambiguity first. The
defence exists — in production shape it is the edge that provides it.

That generalises, and §2 measures how far.

## 2. Seven refusals that the edge normalises away

Twenty of the 47 cases behave differently through the pair. Most are the proxy
rejecting malformed framing before Druse sees it — the proxy doing its job. The
interesting subset is the other direction: **direct = refused, proxied = 2xx.**

| Case | Direct | Proxied |
|---|---|---|
| duplicate identical Content-Length is rejected | 400 | **201** |
| truncated chunk is rejected | close | **200** |
| missing zero terminator is rejected | close | **200** |
| obs-fold header continuation is rejected | 400 | **200** |
| tab obs-fold header continuation is rejected | 400 | **200** |
| bare LF line termination is rejected | close | **200** |
| absolute-form whose authority DISAGREES with Host is rejected | 400 | **200** |

In every one of them Caddy resolved the ambiguity and forwarded exactly one
unambiguous request, and `isolated_desync_hits=0` says no second request came
with it. **None of these is a vulnerability.** What they are is a statement about
where the assurance lives:

- Druse's deliberately stricter-than-RFC refusals (WP9 D2: *"refuse, do not
  normalize"*) are **mostly not exercised** behind the supported edge;
- the pair's safety for these shapes therefore rests on Caddy's normalisation
  being correct, and **nothing in this repository tests Caddy**;
- which argues *for* the supported profile's existing rule — one reviewed proxy,
  named and pinned — rather than against it. Swap the edge for one that forwards
  raw and these seven refusals become load-bearing again.

## 3. Four instrument defects, every one of which read as a product finding

The comparison ran four times. The first three produced tables that looked like
discoveries about Druse and were not. Recorded in full, because the pattern is
the result.

| Defect | What the table said | What was true |
|---|---|---|
| the payload parser dropped `\xNN` escapes | "Druse answers 200 to a NUL in a header value" | the characters `\`,`x`,`0`,`0` went on the wire — a well-formed header. Druse answers 400, and always did |
| the parser did not know Odin **raw string literals** (backticks) | eight rows including "valid Content-Length body" answered `CLOSED-NO-RESPONSE` | every payload with a body was truncated at the header terminator; Druse waited for 16 bytes that never arrived and closed on its read deadline |
| the `#load`ed fixture was read in **text mode** | "F-005's 431 fix has a hole: the many-lines shape answers nothing" | universal-newline translation rewrote every CRLF as a bare LF; Druse rejected bare-LF headers, which is what the corpus's own "bare LF line termination is rejected" case requires |
| the origin registered `GET /nobody` where the corpus sends `DELETE` | the 204 response-framing case answered 405 on both legs | a method is part of a route — the same class as the first attempt at this script, which used an origin serving entirely different paths |

**The check that caught all four** is `agrees()`: the direct leg is compared
against the corpus's own `outcome` and `allowed_status` *before* the proxy column
is read at all. A framing harness that cannot reproduce the suite's own results
has no standing to report a proxy finding. The final run reports **`direct leg
disagreeing with the corpus: 0`** across all 47 cases — including both F-005
cases at 431, on both legs.

The parser now also **refuses to replay** any case whose payload expression holds
a term it cannot evaluate, instead of silently sending a shortened one. Two cases
build their bytes from `#load`ed constants; those are resolved, and anything else
would be reported as skipped rather than passed.

Readiness rule G2 is the rule this keeps illustrating: a failure of the
instrument reproves the campaign, not the product.

## 4. What this does NOT establish

- **Not a proof that Caddy is correct.** Seven Druse refusals are normalised away
  by the edge, and this repository tests neither that normalisation nor its edge
  cases. The assurance for those shapes is inherited from an unaudited
  dependency; that is stated here, not closed.
- **Not a general smuggling result.** Forty-seven cases, one proxy, one version,
  one configuration. A chain with a second hop in front is untested — and a front
  hop that prefers `Content-Length` where Caddy prefers `Transfer-Encoding` is
  the classic vector this corpus cannot reach with only one proxy.
- **Not the whole of R2-WP06.** Fuzzing the candidate, the administrative /
  upload / static / `trust_proxies` endpoint review, and the F8 / F12 / F-007
  indirect pins are open.
- **Not a capacity, stability or canary result.** R2-WP04, WP05 and WP07 are
  untouched by this package.
- **The `Expect: 100-continue` row reads `100` on the proxied leg** because this
  harness reports the FIRST status line and the proxy relays the interim
  response. An artefact of the reporting, left visible rather than special-cased.
