# Transport Conformance

How Druse proves that a transport is correct, and what "correct" means for
each of the three layers. Written for whoever adds the second adapter — the
future official `core:net/http` one — because the rule is that **every real
transport passes the same corpus**.

## Three suites, three different questions

| Suite | Runs on | Question it answers |
|---|---|---|
| **Contract** (`tests/wp1-…` … `tests/wp8-…`) | the in-memory transport | Does the FRAMEWORK behave? Routing, extractors, JSON, envelopes, 404/405, single commit. |
| **Semantic conformance** (`tests/wp9-semantic*`) | BOTH transports | Do the two transports agree? One matrix, two factories, identical expected results. |
| **Raw-wire conformance** (`tests/wp9-wire`) | real adapters ONLY | Is the wire handling SAFE? Framing, smuggling, connection lifetime. |

The contract suite is not duplicated per backend — that would triple the runtime
to re-answer a question about the framework, not the transport.

The raw-wire corpus is deliberately **never** run against the in-memory
transport. That transport has no TCP parser, so it cannot be desynchronized and
cannot smuggle; pointing framing tests at it would produce meaningless green.

## Why the semantic layer exists

The in-memory transport is fast and convenient, which is exactly what makes it
dangerous: if it quietly diverges from a real socket, the whole test suite goes
green while production breaks (R-10). Two things guard against that.

First, both transports run the **same** matrix from
`tests/support/transport_conformance`, with the same expected results. A
divergence fails exactly one factory and names the scenario.

Second, both drive the **same private driver** (`driver_run` → `driver_cleanup`
in `web/serve.odin`): neutral inbound → Context → dispatch → finalize a missing
response → copy out → release the response → release the request arena. Parity
is therefore structural, not a claim about two similar code paths.

That is also why the in-memory factory is an internal (`package web`) test: it
must reach that private pipeline. The socket factory is an ordinary external
consumer.

## The framing policy (strict on purpose)

The bootstrap adapter **rejects and closes** rather than guessing:

- `Content-Length` together with `Transfer-Encoding`;
- more than one `Content-Length`, **even when the values are identical**;
- a comma-list, negative, `+`-signed, non-decimal or overflowing length;
- any `Transfer-Encoding` other than a single, final `chunked`;
- a chunk with a non-hex or overflowing size, a truncated chunk, a missing CRLF,
  a missing zero terminator, or a malformed trailer;
- a fixed body that ends before its declared length;
- whitespace before a header name or before the colon, and obs-fold
  continuations;
- an invalid request line.

Refusing duplicates outright is stricter than the RFC minimum. It is chosen
deliberately: normalizing ambiguous combinations is where smuggling bugs live,
and Phase 1 has no reason to accept them.

In every rejected case: **the handler never runs**, **the connection closes**,
and **no trailing byte becomes a second request**. The corpus asserts those
three properties directly rather than a particular status code, because a
protocol error detected before a framework-owned request exists may legitimately
be answered by the adapter or closed without a response.

### `Expect: 100-continue`

**Honored by reading the body** (corrective WP C6, friction F8-7). The framework
sends **no** interim `100 Continue` — the vendored auto-continue blocked waiting
for a body that might never arrive, so it stays off — but per RFC 9110 §10.1.1 a
server may omit the interim response and simply read the body, so the request
proceeds and the handler runs. A default client (curl, python-requests) that adds
`Expect: 100-continue` for a large upload sends its body after its short continue
timeout. **Any other expectation** the server cannot meet is still **417** and the
connection closes.

### Unknown methods

A valid but non-Phase-1 method — `PROPFIND`, `HEAD`, `OPTIONS` — reaches the
core as `.UNKNOWN` and follows the ordinary dispatch policy (405 with `Allow`
for a known path, otherwise 404). The transport does **not** answer `501` on its
own, and none of these gains a public `Method` member.

### Headers

Names arrive at the core in ASCII lowercase and values are preserved verbatim.
Header **order** is not part of the contract, public header lookup is not in
Phase 1, and general duplicate-header behavior is deliberately not frozen —
only the `Content-Length`/`Transfer-Encoding` safety rules above are.

## Connection behavior by category

| Category | Handler runs | Connection | Second request |
|---|---|---|---|
| valid request | yes | per `Connection:` | served on keep-alive |
| unread body (handler never calls `web.body`) | yes | reusable | served — the adapter consumed the body |
| over-limit body (> 4 MiB) | **no** | closes | never |
| ambiguous framing (CL+TE, duplicate CL, …) | **no** | closes | never |
| malformed chunked / truncated body | **no** | closes | never |
| malformed syntax (whitespace, obs-fold, request line) | **no** | closes | never |
| `Expect: 100-continue` | **yes** (body read; C6) | per `Connection:` | served on keep-alive |
| `Expect:` unknown expectation | **no** | closes | never |

## What the bootstrap does not do

These are **safe** limitations — the unsafe direction is always rejection, never
silent acceptance:

- **HTTP/2** — a later phase, unscheduled;
- **TLS** — not "later": Druse does not terminate TLS **and will not**. It is
  delegated to the reverse proxy by decision (ADR-046), so a second adapter is
  not expected to bring it either. `docs/operations.md` §1.

Shipped since this list was first written, and no longer limitations:
configurable timeouts and body limits (`web.limits`, Phase 3 and WP46/ADR-031),
graceful shutdown with a bounded drain (`web.stop` and `Limits.max_drain_time`,
WP44), and streaming bodies in both directions (Phase 7 and 7.5). A second
adapter is expected to honour all three.

## Vendored-backend patches

The bootstrap uses a vendored snapshot of `laytan/odin-http`, carrying
twenty-four documented patches, ten of them security-motivated. WP9's corpus
found two **remote denial-of-service crashes** among them (`Content-Length: -1`
and a chunk without CRLF each killed the server process); the Phase-6-freeze
scan later found five more. See `vendor/odin-http/VENDOR.md` for the full list,
the rationale for each, and the update procedure.

## Adding a new adapter

1. Implement the private transport boundary (`web/internal/transport`).
2. Add a factory to the semantic suite and run the **same** matrix.
3. Run the **same** raw-wire corpus — it imports no backend, so it needs no
   changes.
4. A case the new adapter cannot satisfy may be documented as unsupported only
   when its behavior is rejection and closure. Ambiguous acceptance is never an
   acceptable limitation.
