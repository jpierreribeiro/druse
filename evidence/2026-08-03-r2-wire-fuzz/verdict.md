# R2-WP06 — mutational raw-wire fuzz against the candidate

**Decision: 1,500 mutated cases, all four oracles green, zero violations.
Nothing is promoted; the gate stays at R1.**

R2-WP06 asks to "executar fuzz/corpus sanitizado no candidato". The 47-case
corpus is a set of seeds rather than a fuzz run — each case is a shape somebody
thought of. This mutates them so the shapes nobody thought of get a turn.

## The run

| | |
|---|---|
| candidate | `tests/support/wire_origin`, `sha256` in `manifest.txt` |
| cases | 1,500, seed `20260803` — **deterministic**, so any finding replays by index |
| mutators | byte-flip, bit-flip, truncate, insert-interesting, append-seed, duplicate-tail, lie-about-length, crlf-to-lf, splice — evenly drawn, 145–184 each |
| stacking | 0–2 further mutations on top of the first |

## The oracles, and the result

| # | Oracle | Result |
|---|---|---|
| 1 | the server is alive at the end | **yes**. Odin has no recoverable panic, so a faulting handler aborts the process — death is the loudest finding available and the cheapest to check |
| 2 | `/smuggled` was never executed | **0**. The origin serves a route no case addresses; a hit means a mutated byte string made the server run a request nobody sent. This is the strongest oracle one hop can carry |
| 3 | every reply is a well-formed status line, or absent | **0 malformed**. Refusing by closing is permitted (WP9 D6); emitting bytes that are neither is not |
| 4 | no case wedges the connection | see below — 257 client-side timeouts, and they are the client's, not the server's |

Outcome distribution over the 1,500:

```text
closed-no-response  569      status:400  483      status:431   38
timeout             257      status:200   63      status:405   17
status:201           30      status:417   11      status:505    9
status:404            8      status:413    7      status:500    5
status:204            3
```

The shape is what a correct framing parser should produce: a third refused with
400, a third closed without a reply, and the well-formed survivors answered by
the routes the seeds address. **38 × 431** is F-005's fix firing on mutants that
grew the header block, which no hand-written case produced.

### The 257 timeouts are the client giving up, and that was measured

A 17% timeout rate is the kind of number a reader should not have to take on
trust, so it was checked rather than explained. The fuzzer's client timeout is
2 s; the framework's `max_request_time` default is 30 s. A truncated request —
headers complete, body short of its announced `Content-Length` — is one the
server is *correctly* still waiting on at 2 s.

Sent by hand with a 40 s client budget:

```text
POST /echo … Content-Length: 100 … {"na     → server closed after 30.2 s
```

The server bounds it at its own documented deadline and closes. So "timeout" in
the table means *this client stopped listening first*, not *the server hung*, and
oracle 4 is green. Had the 30 s deadline not fired, that would have been the
finding of the run.

### The 5 × 500 are the application, not the framework

`wire_origin`'s `/echo` binds a JSON body; a mutated body that is valid framing
and invalid JSON reaches the handler and the handler answers. That is the
fixture's behaviour, and it is left in the table rather than filtered out,
because filtering it would also hide a 500 that meant something.

## One instrument defect, found by running it

The oracle-2 counter read empty and the run reported *"/smuggled was executed
time(s)"* — with a hole where the number belongs. The fuzzer sends NUL bytes, the
origin logs request text, so its log becomes a **binary file** to `grep`, which
then matches nothing and says nothing.

It failed closed, which is the right direction, but an oracle whose message has a
hole in it is one nobody can act on. `grep -a` now, and an unreadable counter is
reported as its own failure — distinct from a non-zero one, because *the server
executed a request nobody sent* and *nobody can tell* are different problems.

## What this does NOT establish

- **Not coverage-guided.** No instrumentation feedback, so this explores the
  neighbourhood of the seeds and no further. 1,500 cases is a **budget**, not a
  statement about the input space, and a clean run is evidence of absence only
  within that neighbourhood.
- **One hop, no proxy.** The pair Caddy+Druse is
  `evidence/2026-08-03-r2-proxy-framing/`; this is the candidate alone.
- **No memory oracle.** Nothing here measures RSS, leaks or allocator behaviour
  under mutation — F8's assertion belongs to R2-WP04's twelve-hour run, and this
  is not it.
- **The fixture is not the product.** `wire_origin` is a small application over
  the framework. Framing, refusal and deadline behaviour are the framework's and
  are what this exercises; the handler behaviour above them is the fixture's.
- **Not a statement about the proxy leg's mutants.** Every case here went
  straight at the candidate. Mutating *through* the edge is a different
  experiment and has not been run.
