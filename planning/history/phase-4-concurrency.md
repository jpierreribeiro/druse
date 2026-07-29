# WP42 — the concurrency prototype, and what it actually showed

**Date: 2026-07-21. Toolchain: the pinned commit (`819fdc7`). Machine: 8 cores.**

This document is the evidence behind **ADR-030**. It records both arms, the
losing arm's numbers, and — more usefully — the two things the measurement could
**not** show, because a prototype write-up that only lists what it proved is a
sales document.

---

## 1. What the arms are

Both already exist. `Server_Opts.thread_count` in the vendored server defaults
to the core count, and **Druse's adapter forces it to 1**. So this was never a
build; it is a one-line change — which is precisely why it needed measuring
rather than assuming. **A cheap change is the kind that gets made without
evidence.**

* **Arm A — single-threaded.** `opts.thread_count = 1`. The status quo.
* **Arm B — threaded.** `opts.thread_count = 8` (core count).

The harness is `experiments/12-concurrency-arms/`. It copies the tree, patches
one line, builds a real consumer against each, and drives both with identical
client load. It changes nothing in the repository.

---

## 2. The timing, and why it decides nothing

400 requests, 16 concurrent clients, `-o:speed`, one JSON response per request:

| Arm | Wall clock | HTTP 200 | Responses |
|---|---:|---:|---:|
| single-threaded | 1,861 ms | 400 | 400 |
| threaded (8) | 1,288 ms | 400 | 400 |

**Threaded finished about 31% sooner, and both arms answered every request
correctly.**

**That 31% is not a result.** FINDING-A's noise floor on this machine, derived
by the WP26 harness at the Phase-3 freeze, is **13,821 basis points — 138%**.
A difference of 31% sits far inside it. The workload is also partly bound by
spawning `curl` processes rather than by the server, which inflates the floor
further.

**By the rule the Phase-4 plan pre-registered before any of this ran** — *the
burden of proof is on threading, and an inconclusive prototype means
single-threaded* — the timing arm is **inconclusive**, and inconclusive has a
defined meaning here rather than an inviting one.

---

## 3. What actually decides it: three single-writer sites

Threading is not blocked by performance. It is blocked by **guarantees the
framework currently states as true, which `thread_count > 1` silently makes
false.** Each was read at this commit:

### 3.1 The request-ID counter

`web/request_id.odin` increments a package counter **without atomics**, and the
code says so itself:

> *"The counter is incremented without atomics, and that is a stated assumption
> rather than an oversight: exactly one server per process is supported (audit
> R-10) and the transport's event loop is single-threaded, so no two dispatches
> race here. Phase 4 owns concurrency, and it owns this line with it — a
> multi-threaded dispatcher must make this an atomic increment or two requests
> can be handed the same ID."*

The Phase-1 freeze repeats it as a frozen assumption. A duplicated request ID is
not a crash; it is **two different requests that correlate to one line in a log**
— the failure mode of a diagnostic tool, discovered while diagnosing something
else.

### 3.2 The lazily-built miss chain

`web/middleware.odin` builds the 404/405 chain on the **first miss**, guarded by
`miss_built`. That is a check-then-act on shared state feeding an append-only
pool: two threads can both observe `!miss_built`, both append, and one then holds
index pairs into a region the other overwrote. This one is worse than the
counter, because its consequence is a **wrong chain**, not a wrong label.

### 3.3 `dispatched`, and application state

`a.private.dispatched = true` is written per request, and it is the flag the
ADR-019/ADR-023 fail-closed guards read. `web.state` hands every handler a
pointer to one shared value, and `examples/07-app-state` documents its `+= 1` as
correct **"under the framework's current model — one server per process, one
event loop."**

---

## 4. What I could NOT show, stated because it matters

**I did not observe a request-ID collision.** A probe ran 300 requests across 12
concurrent clients against the threaded arm and produced no duplicate ID. The
race is real **by construction** — a non-atomic read-modify-write on shared
state — but "the code cannot be safe" and "I saw it fail" are different claims,
and only the first is supported here. Low contention on x86 hides this kind of
race routinely; a soak (WP53) with a tighter loop is where it would surface.

**And my first reading of that probe was wrong.** It showed 141 of 300 responses
empty under threading, which looked like a serious defect. Running the *same
probe against the single-threaded arm* produced **133 of 300 empty** — so the
empty responses were an artefact of the harness (twelve subshells writing into
one unbuffered redirect), not of the server.

**The control is the only reason that did not become a finding.** It is the same
lesson as WP41's control 3, arriving from the other direction: there, the
question was whether a finding was about the server; here, an apparent finding
turned out not to be.

---

## 5. The decision

**Single-threaded, and the burden stays on threading.** See ADR-030.

The timing did not separate the arms. The correctness reading did: adopting
threading today would require, in the same change, an atomic counter, a
synchronised miss-chain build, a synchronised `dispatched` flag, and a
documented rule about `web.state` under concurrency — **four amendments to
shipped guarantees, in exchange for a speed-up this machine cannot measure.**

That is not a refusal of threading forever. It is a refusal to adopt it as a
side effect of a one-line change, which is exactly what it would have been.

**What would reopen it**, written now so it is not written to fit a later
preference:

1. a workload measured on an instrument whose noise floor is materially below
   the observed difference — WP53's job, not a rerun of this one;
2. the four amendments above prototyped and passing the WP41 fault lab;
3. evidence that a real deployment is CPU-bound in the framework rather than in
   the handler, since a threaded server does not help a program whose time is
   spent in the database.
