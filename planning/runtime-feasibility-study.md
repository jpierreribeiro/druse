# A task runtime for Druse — feasibility study

**Status: DRAFT WITH A RECOMMENDATION, 2026-08-03. The owner decides.**

**The question.** The owner's objective is to make Druse viable for real systems
**without the limitations `docs/supported-profile.md` declares** — not speed, and
not parity with Tokio or the Go ecosystem. So this study asks: **which declared
limitations does a runtime of our own actually remove, and is there a cheaper
instrument for each?**

**Short answer, developed in §0 and §8b.**

- **Buildable in Odin?** Yes, in one shape only — thread-per-core with explicit
  state machines. Tina proves it, in Odin, at ~51k lines.
- **Does it remove the limitations?** **Two of six clearly** (platforms, the
  vendor fork). One at a cost that changes what Druse is. **Three not at all** —
  including the worst one, handler-fault containment.
- **What it costs.** Four to five years and several scheduler rewrites at the
  reference implementation's scale.
- **The recommendation:** **take ownership of the I/O layer first.** It is the
  same first step whether or not a runtime follows, and it unblocks the
  limitation that hurts most in production — which is the one a runtime helps
  least with.

**Speed is treated in §1 and is secondary.** It is kept so the record shows it
was examined, and so nobody adopts a runtime expecting a speed-up it would not
deliver.

**Predecessor.** `planning/sync-async-evaluation.md` (2026-07-22) is the
research contract that defines four arms and a functional-equivalence gate. This
document does not replace it. It asks what comes *before* the arms: **should the
arm exist at all, and can it be built in this language?**

> **Rule carried over from that contract, and it governs this one:**
> *"Preference is a hypothesis; measurements and ownership decide."*

**Standing obligation.** R2 is not finished. WP04–WP08 remain and the campaign
host is qualified and idle. Nothing in this study licenses leaving a readiness
gate half-open.

---

## 0. The question this study is actually answering

**Corrected 2026-08-03, after the first draft aimed at the wrong target.**

The first draft evaluated the runtime as an instrument for **speed**, and
concluded — correctly, for that question — that syscall levers are cheaper. That
was the wrong question.

**The owner's objective is not speed and not parity with Tokio or Go. It is to
make Druse viable for real systems without the limitations `docs/supported-profile.md`
declares.** Speed is a consequence, not the goal.

So the question is:

> **Which of Druse's declared limitations does a runtime of our own actually
> remove, which does it not, and is there a cheaper instrument for each?**

### 0.1 The matrix, which is the whole study in one table

The six limitations, as listed to the owner, against what a runtime does to each.

| # | Limitation | Does a runtime remove it? | Cheaper instrument |
|---|---|---|---|
| 1 | **A handler fault kills the process** | **No, not really** — see §0.2 | **worker processes** (R3-WP10) |
| 2 | **Handlers are synchronous; one occupies a lane** | **Yes — by replacing them with state machines**, which removes the product's reason to exist (§3.2) | bounded worker pool (arm B) |
| 3 | **No native TLS / HTTP2 / WebSocket** | **No.** Owning the transport is a *precondition*, not the work. HPACK, flow control, GOAWAY and the smuggling corpus remain | none — it is protocol work either way |
| 4 | **Linux x86-64 only** | **Opens the way; does not remove it.** We are pinned to io_uring through `core:nbio`, and a backend abstraction is the exit — Tina ships io_uring, kqueue and IOCP. But Tina's own dossier lists *"correção real em FreeBSD/Linux ARM"* as **not proven**, and "supported" costs the R3-WP03 campaign per platform (corpus, soak, equivalent proxy/supervisor) — which is the expensive part, runtime or not | taking ownership of the I/O layer (§4.5) |
| 5 | **43 vendor divergences in a forked backend** | **Yes, materially** — with a trade: it retires the fork and takes on ~16.5k lines of someone else's HTTP, plus the runtime beneath it. Maintenance moves, it does not vanish | R3-WP02 arm C: migrate to a future `core:net/http` |
| 6 | **pre-1.0, no LTS or backports** | **No.** This is release policy (R3-A) | write the policy |
| 7 | **A reviewed reverse proxy is required in front** (`supported-profile.md:29–36`) | **No.** Tina has no TLS either, and the proxy supplies HSTS, edge rate limiting and public HTTP/2 that nobody plans to nativise. Added 2026-08-03 (audit H): it was on the list given to the owner and had been dropped from this matrix, which left the selection open to the charge of picking rows | none — and it is the cheapest limitation on the list |
| 8 | **"An application CPU/job runtime" is explicitly outside the profile** (`supported-profile.md:38–39`) | **This is row 2 by its other name**, and it is the most literal limitation of all for a study about a runtime. Added 2026-08-03 (audit H) | see row 2 |

**Two of eight clearly, one of them with a trade. One at a cost that changes the
product — twice, since rows 2 and 8 are the same limitation. Four not at all.**

### 0.2 Row 1 is removable only at the price of row 2

This deserves care, because "supervision" sounds like it should.

Tina has supervision, shard recovery and quarantine. Its own dossier records the
limits:

- *"os shards compartilham o espaço de endereçamento do processo; guard pages
  detectam certas ultrapassagens, mas não são isolamento de segurança"*;
- *"uma falha de hardware aciona recuperação do shard inteiro, não apenas do
  isolate que falhou"*;
- and an open question it does not answer: *"O recovery com `siglongjmp`
  preserva quais garantias após corrupção que não atingiu guard page?"*

**Corrected 2026-08-03 after audit finding E: the first draft used the weakest
argument available, and caricatured the alternative.**

Two repairs. First, the dossier discards `siglongjmp` *"para o Uruquim, que usa
um backend e não controla todo o processo"* — a premise a runtime of our own
would remove. And shard recovery's practical blast radius is **the same 1/N as
worker processes**: a worker that dies also loses its in-flight connections;
R3-WP10's positive control measures exactly that the requests *on the other
workers* do not fail. What processes buy is not a smaller radius — it is a
**guarantee after corruption**, an address-space boundary against Tina's own
open question: *"o recovery com `siglongjmp` preserva quais garantias após
corrupção…?"* So the precise formulation is **"same radius, weaker guarantee,
and a proof obligation nobody can close"** — which still decides for processes,
without caricaturing a mechanism a real project ships.

Second, and this is the argument that actually closes it: **shard recovery is
only honest because Tina's whole architecture was designed for reconstruction**
— per-shard arenas, universal generational handles, transactional commit of
effects. Druse's state was not: a request arena, `odin-http` connections, an
`nbio` loop. **Adopting the discipline that makes `siglongjmp` defensible is the
cost of row 2** — the state-machine model that changes the product.

> **So row 1 is not "a runtime does not remove it". It is "a runtime removes it
> only at the price of row 2"** — which unites the two worst rows of the matrix
> under one prohibitive cost, and is a far stronger conclusion than the first
> draft's.

**Real containment therefore needs an address-space boundary: separate
processes.** That is R3-WP10, already measured (ADR-051: resources are *not* the
obstacle), blocked on one nameable thing — `nbio` cannot adopt a socket it did
not create.

**The evidence that would reopen this judgement**, recorded so the position is
falsifiable: a fault-injection campaign against Tina — which has DST and death
tests — with induced corruption, a **red negative control**, and invariants
shown to survive `siglongjmp`. With that, "hoping" becomes engineering and row 1
must be re-judged. Without it, and with ADR-020 closed in definitive, the
judgement stands.

### 0.3 What the two "yes" rows have in common — they are one problem

Limitations 4 and 5 — platforms and the fork — are the same problem wearing two
hats: **we do not own the I/O layer or the HTTP backend.**

A runtime of our own solves that by replacing both. But so does the smaller move
already identified in §4.5: **take ownership of the I/O layer.** That single
decision unblocks R3-WP10 (limitation 1), opens the path to other backends
(limitation 4), and is the precondition for retiring the fork (limitation 5).

**It is the same first step either way.** Whether it ends at "vendored nbio with
a socket-adoption entry point" or continues into a full runtime is a decision
that can be taken *after* the first step, with the code in hand.

---

## 1. The speed question, and why it is secondary

**Kept because it was asked, and because the answer bounds expectations.** Speed
is not the objective (§0); this section exists so nobody later claims the runtime
was rejected without examining performance, or adopted expecting a speed-up it
would not deliver.

### 1.0 The motivation, checked against our own evidence

The stated reason is speed. Before designing anything, the honest state of the
performance evidence in this repository:

### 1.1 What is settled

**Corrected 2026-08-03 after audit finding B.** Two items were listed here as
settled facts and are history: they describe code that no longer ships.

- **Latency is excellent and reproducible.** The p99 results reproduced across
  re-measurement and stand; against fasthttp the framework held a *lower*
  absolute p99. This one is settled.
- **Multishot recv was refuted as the throughput lever**, by measurement, not
  by argument: 216k (one-shot) vs 213k (multishot) per core, head to head. The
  obvious fix was tried and did not work.
- ~~**The framework adds no measurable overhead over bare `nbio`** (~78k both)~~
  — **retired.** That measurement is pre-dedicated-accept
  (`perf-wp-multishot-scanner.md:43–52`, framework 4.97 enters/req against the
  echo's 4.99). The default path now does **0.160 enters/req at 259k**, which is
  3.3× above the "ceiling" the sentence asserted. A ceiling the product itself
  cleared is not a settled fact.
- ~~**Cheap io_uring flags were refuted**~~ — **downgraded to "provenance not
  traceable".** The `DEFER_TASKRUN` refutation says "patched into nbio, rebuilt,
  benchmarked — throughput flat", and the neighbouring line cites
  `vendor/nbio/impl_linux.odin` — **a file the server does not load.** ADR-051
  established that `vendor/nbio` is imported by two benches and nothing else,
  and that the product uses `core:nbio` from the toolchain. If the patch went
  into `vendor/nbio` and the benchmark ran `web.app`, "throughput flat" is the
  guaranteed result of a no-op. The refutation may well be valid — the record
  does not say which binary was rebuilt, and this repository's own rule is that
  an untraceable number is an anecdote. **Re-run it if the lever matters again.**
  The same discount applies to "`COOP_TASKRUN` was already on": the citation
  points at the same unloaded file.

### 1.2 The 3× "contradiction" was mine, and the repository had already resolved it

**Corrected 2026-08-03 after audit finding A. The first draft of this section
was wrong, and it was the load-bearing argument of §1.3.**

It claimed the two disagreeing throughput figures — 259k/283k and ~80k/116k —
"both describe code that ships", on the strength of `DRUSE_DEDICATED_ACCEPT`
being `#config(..., true)` today. **They describe different code.** Verified in
this tree:

- the ~80k re-measurement is commit `44a169f` (2026-07-25 **16:14**);
- the dedicated accept merged at `5593536` (**22:08**, six hours later);
- `git show 44a169f:vendor/odin-http/server.odin` contains **zero** occurrences
  of `DRUSE_DEDICATED_ACCEPT`. The flag did not exist in the code that measured
  ~80k.

And the file I cited resolves it, in the addendum immediately after the section
I quoted (`perf-netpoller-study-and-architecture.md:514–539`): *"The correction
above accurately describes `origin/main`, but its conclusion … is superseded by
a measured implementation."* The mechanism is quantified — `io_uring_enter` from
~5.03 to **0.160 per request**, a 31× cut, by taking the accept cancel/re-arm
out of the hot path. That is precisely the iowait-bound pattern the
re-measurement had diagnosed.

The provenance of 259k/283k is the strongest in the tree: five-run A/B against
the old bound, syscall counts by `perf stat`, full gate green, three consecutive
C-03 campaigns.

**So the honest reading is "resolved by a code change", not "an open 3×
contradiction".**

**One loose end survives, and it is a real one.** The *distributed* load shape
(four destination IPs) that produced ~80k has never been re-run against the
dedicated-accept code — no report from 2026-07-26 to 08-01 repeats it. Anyone
wishing to keep the "259k is a single-destination artefact" hypothesis alive has
a named experiment: `wrk` 4×1-thread → `127.0.0.{1..4}` on the current binary.

### 1.3 What this means for the decision

**Also corrected.** The first draft made a two-box measurement a *precondition*
for deciding anything, on the strength of the contradiction that §1.2 has now
dissolved.

The best number from the code that ships is **259k/283k = 91.7%/96.6% of
fasthttp**, single-box. That **already satisfies this study's own abandonment
criterion §8.2** — "a reproducible two-box measurement shows the current
framework within ~20% of the fasthttp class" — modulo the box count.

The two-box round is still owed, and remains owed: loopback under-measures
io_uring and puts the generator on the machine under test. But it is
**confirmation and benchmark hygiene, not the gate on this decision.**

The effect on the recommendation is to strengthen it: the speed rationale for a
runtime is emptier than the first draft claimed, not fuller.

---

## 2. What "a runtime" means, so the word stops covering four things

Tokio is cited as the model. Tokio is **four separable components**, and Druse
already has one of them:

| Component | What it does | Druse today |
|---|---|---|
| **Reactor** | waits on many fds, dispatches readiness/completion | **exists** — `core:nbio` over io_uring |
| **Task executor** | schedules M user tasks over N threads, suspends and resumes them | **absent** |
| **Timer wheel** | efficient many-timer scheduling | partial — `nbio` timeouts |
| **Sync primitives** | async-aware channels, mutexes, semaphores | absent (blocking `core:sync` only) |

The missing piece is the **executor**, and the executor is the part that needs
language support. This distinction matters because "we need a runtime" is often
heard as "we need better I/O" — and our I/O layer is not the thing that is
missing.

---

## 3. The language constraint, which may be decisive

**Odin has no `async`/`await`, no generators, no coroutines, and no closures
that capture by move.** A task executor must be able to *suspend a computation
in the middle and resume it later*. There are exactly three ways to get that,
and Odin supports at most one of them today:

| Mechanism | How it suspends | Needs compiler support? | Viable in Odin? |
|---|---|---|---|
| **Stackless state machines** | the compiler rewrites a function into a state machine (Rust/C# `async`) | **yes** | **no** — unless written by hand at every call site, which is not a framework, it is a burden on every user |
| **Stackful coroutines / fibers** | swap the machine stack (`ucontext`, or hand-written asm) | no, but needs a stack allocator and unwinding discipline | **no — B0: the language's author has ruled it out** |
| **OS threads** | the kernel suspends | no | **yes — this is what Druse already does** |

Three consequences follow, and they should be read carefully:

1. **The Tokio model is not portable to Odin.** Tokio's ergonomics come from
   `async fn` — a compiler transform. Without it, "async Druse" means
   applications writing explicit state machines, which is worse for users than
   the synchronous handlers we ship today.
2. **The realistic runtime shape is stackful**, if Odin can host it, or
   **thread-per-core share-nothing**, which needs no suspension mechanism at
   all — that is the Seastar/Glommio family, and it is the one model that is
   clearly implementable in Odin today.
3. **Stackful coroutines carry costs the "looks synchronous" framing hides**,
   and `sync-async-evaluation.md` §3 arm D already lists them: stack memory per
   task, `defer` semantics across suspension, thread-local context, FFI that
   blocks the whole carrier thread, scheduler fairness, and cancellation.

> **This was Research Block 0, and it was the gate. It has been answered.**
> Odin has no fiber mechanism and its author has stated it will not get
> Go-style concurrency — *"Odin will NEVER do this"* (§6b/B0). **Arms C and D
> are closed**, and "runtime" can only mean thread-per-core or explicit state
> machines. §3.1 and §3.2 develop what that costs.

### 3.1 Block 0 is largely answered, and the answer is in this repository

**`tina/docs/` is a 3,185-line dossier on a runtime of exactly the shape §3
concluded was the only feasible one — and it is written in Odin.**

> **Provenance.** That directory is **not in this repository** — it is excluded
> by `.git/info/exclude`, a local exclusion rather than project policy. Every
> file it contains is hashed in
> [`runtime-tina-dossier-provenance.md`](runtime-tina-dossier-provenance.md) so
> a reviewer can obtain the same bytes and check any quotation below. Audit
> finding D: a citation a reviewer cannot audit is an assertion.

Tina (`github.com/pmbanugo/tina`, studied at commit `24b2cb9`, Apache-2.0) is
**160 files, 121 of them `.odin`, ~51k lines**, with io_uring, kqueue and IOCP
backends plus a simulated one, supervision, and deterministic simulation
testing. Its HTTP server is ~16.5k of those lines.

Two findings change §3 outright:

**1. It is buildable in Odin. This is no longer a question.** A thread-per-core
shared-nothing runtime with async I/O, generational handles, backpressure,
supervision and DST exists in this language today.

**2. It suspends without coroutines at all.** A handler receives state, a
message and a context, and returns a **two-byte transition** — `Done`, `Yield`,
`Wait_Message`, `Wait_Reply`, `Wait_Io`, `Crash`. There is no stack to swap and
no compiler transform. The suspension problem is dissolved rather than solved:
the application is written as an explicit state machine, and the scheduler drives
it.

So Research Block 0's *feasibility* half is answered **yes**. What remains open
is its *ergonomics* half, and it is the crux — see §3.2.

### 3.2 The cost Tina makes visible, and it is not performance

The dossier's own comparison is blunt about where the two projects sit:

| Axis | Tina | Druse |
|---|---|---|
| API | **low level, state machines** | **high level, web ergonomics** |
| philosophy | *constraints first* — the user sizes capacities and writes state machines | *pleasant backend first* — the user writes a synchronous handler |
| concurrency | thread-per-core shared-nothing | inherited from the backend |

> *"O usuário dimensiona capacidades e escreve máquinas de estado. A
> complexidade é paga na configuração e no runtime para obter previsibilidade."*
> — `08-comparacao-com-uruquim.md`

**This is the real trade, and it is a product decision rather than a technical
one.** The transition-returning handler is exactly the "hand-written state
machine" that §3 identified as the cost of a stackless model without compiler
support. Tina does not avoid that cost — it *accepts* it deliberately, and gets
predictability in return.

Adopting that model in Druse would replace the thing Druse is for. A framework
whose selling point is *"write an ordinary synchronous procedure"* cannot ask
users to return `Wait_Io` without becoming a different product.

### 3.3 What Tina does NOT establish, from its own dossier

The study is admirably honest, and these are its words, not a reading of them.
`10-limitacoes-e-questoes-abertas.md` lists as **not proven**:

- **"throughput ou latência superior do Tina"**;
- safety against malicious code in-process (shards share the address space;
  guard pages are not a security boundary);
- behaviour under NUMA/multi-socket;
- absence of races beyond what TSan and the tests exercised;
- compatibility with proxies, TLS terminators and diverse HTTP clients.

**And the only head-to-head benchmark was invalidated:** `ab -k` sent HTTP/1.0,
Tina requires HTTP/1.1 and answered non-2xx while Druse answered normally. The
numbers were discarded.

> **This matters more than anything else in this section.** Tina proves the
> architecture is *buildable in Odin*. It does not provide one measured data
> point that it is *faster*. The speed motivation for a runtime gains a
> feasibility proof and **no** performance evidence.

### 3.4 One structural lesson we already paid for

Tina applies generational handles universally — *"o índice localiza; a geração
valida identidade"* — to isolates, file descriptors, handoffs, buffers **and
HTTP tokens**.

Druse applies the same pattern in its stream registry, and **STREAM-001
(2026-08-03) was that pattern failing where it had not been applied**: the
`Stream_Link`, which lives *outside* the registry and is indexed by slot, was
recycled with no generation of its own, so a stale teardown reached a live
stream. The registry's generation check could not see it, because the link held
the new token.

The lesson generalises beyond the fix that was shipped: **every recycled index
in this codebase wants a generation, not only the ones inside the registry.**
That is a review to run, and it is cheap relative to a runtime.

---

## 4. Constraints the current codebase puts on any runtime

These are properties of Druse as it exists, gathered from the code. Any runtime
must satisfy them or explicitly buy them out.

### 4.1 Request-lifetime arena

`web/request_arena.odin` owns decoded nested data for the life of one request
(ADR-006). It is package-private and reaches `Context_Internal`.

**Constraint:** a task that outlives its request, or migrates to another thread
mid-flight, must not hold arena-derived pointers. The existing contract already
demands this of every arm — *"zero lifetime escape of `Context`/arena"* — and
it is the single most likely source of memory unsafety in any executor work.

### 4.2 Cancellation is explicit, final, and thread-affine

From `planning/closure-async-op-inventory.md`, pinned facts about `nbio`:

- `nbio.remove` is **final and silent** — the callback never fires, no error is
  delivered, and calling it on an operation whose callback already ran is a
  use-after-free;
- it must be called **from the owning loop's thread** or it panics;
- `nbio.num_waiting()` counts every outstanding operation, so **any operation
  whose handle was dropped extends shutdown**.

**Constraint:** a work-stealing executor that migrates tasks between threads
collides with all three. Thread-affine ownership is not a style choice here; it
is what the cancellation model is built on. This is a strong argument for
**thread-per-core** over work-stealing, independent of performance.

The inventory tracks **27 operation-creating call sites** in nine kinds, and
`build/check_c01_controls.sh` fails if the tree grows one the table does not
name. Any runtime adds sites to that inventory.

### 4.3 The detached-stream machinery already is a cross-thread executor

Phase 7 shipped a registry with slots and generations, bounded cross-lane
delivery, and owner-lane wakeup (`web/internal/stream/`). `sync-async-evaluation.md`
§3 arm B is explicit that this *"is the natural substrate for this arm and must
be reused, not duplicated."*

**Constraint, and an opportunity:** we already own a working bounded cross-thread
hand-off with stale-safe tokens. A worker-pool arm is not a greenfield.

**And a warning, freshly paid for.** STREAM-001 (2026-08-03) was a slot-reuse
defect in exactly this machinery: a recycled slot let a stale teardown close the
wrong stream, silently. That is the class of bug an executor multiplies.

### 4.4 No FFI in the core

`web/` imports no foreign symbols. Blocking dependencies (PostgreSQL, HTTP
clients) live in **druse-crystals**, a separate repository, and are not a
dependency of `web`.

**Constraint:** this is good news for the core's purity and bad news for the
speed argument — see §5.

### 4.5 We do not control the I/O layer, and this already blocks another track

`web/internal/transport/odin_http_adapter.odin` imports **`core:nbio`** — from
the pinned toolchain. A `vendor/nbio` exists in the tree and **the product does
not use it**; ADR-051 established that it is imported by two benchmarks and
nothing else, which is why a patch believed to be "one line" turned out to be a
no-op in a file the server never loads.

This is not a detail. **Two independent tracks have now hit the same wall:**

| Track | What it needs from `nbio` | Status |
|---|---|---|
| R3-WP10 — fault containment | adopt a socket it did not create (for `SO_REUSEPORT` or an inherited listener) | **blocked** (ADR-051) |
| this study — any executor | scheduling/wakeup integration with the event loop | would need the same kind of entry point |

**Constraint, and possibly the most actionable finding in this document:** any
serious runtime work requires either upstreaming into `core:nbio` or a policy
decision to vendor it. That is the same decision R3-WP10 is already waiting on —
so it should be taken **once**, for both, rather than twice.

There is precedent for building this class of thing here: `vendor/uring_buf_ring`
is a provided-buffer ring ABI written from scratch and proven against kernel
6.8 (WP115), because the toolchain shipped `provide_buffers` and `read_multishot`
as empty `unimplemented()` stubs. Capability is demonstrated. What is missing is
a decision about ownership of the layer.

### 4.6 A handler fault kills the process

Odin has no recoverable panic (ADR-020, closed *in definitive*). The mandatory
failure domain is a supervised unprivileged process behind a proxy.

**Constraint:** a runtime does **not** change this. If anything it worsens the
blast radius, because more concurrent work is lost per fault. Fault containment
is R3-WP10 and is a *separate* project, currently blocked on `nbio` being unable
to adopt a socket it did not create (ADR-051).

---

## 5. The question that decides whether speed reaches the application

A runtime speeds up a server by letting it do other work while waiting. **If the
thing being waited on blocks an OS thread anyway, the runtime buys nothing.**

For a web framework the dominant wait is the database. So:

- if the PostgreSQL driver used by applications is **libpq**, a blocking C
  library, then every query holds its carrier thread whatever the executor does;
- the runtimes that solved this — `tokio-postgres` (Rust), `pgx` (Go) —
  **reimplemented the PostgreSQL wire protocol** rather than wrapping libpq.

**Corrected 2026-08-03 after audit finding G. The first draft overstated this
twice.**

It said async "implies" writing the wire protocol. There is a production
counter-example the research itself describes before dismissing it:
**`psycopg3` does real async over libpq's own non-blocking API** —
`PQconnectStart` / `PQsendQuery` / `PQconsumeInput` / `PQisBusy` driven by socket
readiness, with pipeline mode from libpq 14. Diesel concluded "not efficiently"
*for Diesel's architecture*. The path is thorny — single-row mode, and the weak
cancellation B5 notes, which is equally weak on every path — but **"laborious"
is not "requires reimplementing the wire".**

The honest conclusion is a ladder of decreasing cost and decreasing gain:
**wire protocol, or non-blocking libpq driven by the loop (precedent:
psycopg3), or a bounded worker pool.**

It also called the wire protocol "a second project of comparable size to the
runtime itself" — a superlative with no source, contradicted by this tree:
`planning/phase-6-plan.md:47` records that *"Odin implementations demonstrate
protocol viability"*. The runtime was costed in team-years (B6);
`tokio-postgres` is not that class. **The qualitative point survives** — this
cost is real and must be in the accounting — **the "comparable size" does not.**

And `pgbouncer` or a local proxy is not an escape, which is worth one line
rather than silence: it multiplexes connections on the *server* side and does
nothing to unblock the calling thread.

---

## 6. Candidate arms

Reusing the numbering from `sync-async-evaluation.md` §3 so the two documents
stay joined, with feasibility added.

| Arm | Shape | Needs fibers? | Feasible in Odin today | Note |
|---|---|---|---|---|
| **A** | bounded synchronous lanes (**shipped**) | no | yes | the baseline every arm must beat |
| **B** | event lanes + bounded worker pool | no | **yes** | substrate exists (§4.3); does not need a runtime |
| **C** | fully async application execution | yes (or hand-written state machines) | **blocked on Block 0** | Tokio-shaped; needs the compiler support Odin lacks |
| **D** | synchronous-looking facade over fibers | **yes** | **blocked on Block 0** | Go-shaped ergonomics, without Go's compiler/GC |
| **E** *(new)* | **thread-per-core, share-nothing** | **no** | **yes — Tina proves it** | Seastar/Glommio family; fits §4.2's thread affinity |
| **F** *(new)* | **keep the synchronous facade, swap the transport under it** | no | **needs measurement** | Druse's boundary is already substitutable; Tina behind `web.app` |

**Arm E is new to this document** and deserves attention precisely because it
needs no language feature Odin lacks, and because §4.2 shows our cancellation
model already assumes thread affinity. §3.1 establishes it is buildable in Odin.

**Arm F is the one the Tina dossier hints at and nobody has costed.** Its own
comparison closes with:

> *"Essas filosofias podem cooperar se a fronteira de transporte permanecer
> limpa."* — `08-comparacao-com-uruquim.md`

Druse's transport boundary **is** clean and substitutable by design
(`web/internal/transport/boundary.odin`; the adapter is private). So the shape
is: applications keep writing ordinary synchronous handlers, and a
thread-per-core runtime replaces `nbio` + `odin-http` underneath.

**Corrected 2026-08-03 after audit finding C. The first draft killed this arm
with a false comparison.** It said a blocking handler under thread-per-core
"stalls every connection on that core — strictly worse than today's bounded
lanes". That is wrong about *today*:

- since the dedicated accept, a connection is **affine to its lane for its
  entire lifetime** — parsing, dispatch, sends, deadlines and teardown
  (`docs/reports/2026-07-25-dedicated-accept-throughput.md:99–106`);
- the handler is synchronous and occupies that lane
  (`docs/supported-profile.md:43–44`).

So **today** a blocked handler already stalls every connection assigned to its
lane. That is the same 1/N blast radius as a stalled shard. WP69/WP72 prove the
*other* lanes progress — exactly as other shards progress under Seastar or Tina.
"Strictly worse" was false; it is **the same radius**. The residual difference
is smaller and elsewhere: Druse's acceptor steers *new* connections to the least
loaded lane, which `SO_REUSEPORT` hashing does not — though Tina's coordinator
topology does.

**What actually prices Arm F, and the first draft never computed:** adopting
Tina as the transport trades a 43-patch fork of `odin-http` for a dependency —
or a fork — of **~53k lines of single-maintainer, pre-1.0 runtime**, with no
proxy/client interop evidence, **no TLS** (so it does not remove limitation 3),
a linear-scan router, and not one valid benchmark against Druse. That pushes
limitation 6 *down a level and makes it bigger*.

**Arm F does not die of "a blocking handler stalls a shard". It dies — or is
deferred — because its price is becoming co-maintainer of a runtime, for a net
gain of two limitations (4 and 5) that steps 3–4 of §8b remove more cheaply.**

§3.2 stands unchanged: exposing two-byte transitions to the application would
destroy the product's reason to exist. But that argument answers **arm E exposed
to the user**, not this hybrid.

---

## 6b. External research findings (2026-08-03)

The owner executed the research plan. Results, with what each one settles.

### B0 — Odin will not have coroutines. This is a language position, not a gap.

Ginger Bill, on Go-style concurrency: **"Odin will NEVER do this"**. The planned
direction is non-blocking I/O via `core:nbio` — event loop and **callbacks**. He
states he *"ended up picking the callback system"*, and that anyone wanting
coroutines must build them separately (Lua, or a native package).

There is no official issue or plan for stackful coroutines. Third-party attempts
exist (`foldcat/oasync`, a cooperative task scheduler) and are limited — it
cannot even host `time.sleep` inside a task. Community consensus is that
userspace coroutines in Odin are hard and that **`defer` does not survive them**.

> **Settles §3 and closes two arms.** Arms C (fully async) and D (fiber facade)
> are not merely expensive — they are **against the language's stated
> direction**. A framework betting on them would be betting against Odin.

### B1 — Tokio is not portable, confirmed from its own costs

Its ergonomics rest on `async fn` + the `Future` trait — compiler machinery.
Its multi-thread scheduler is M:N with work-stealing, requiring **`Send + Sync`
bounds everywhere**. And the research surfaced the design critique that matters
most here: cancellation-by-dropping-the-Future is described as *"the most
damaging mistake"* of async Rust's design, forcing every async API to be written
"cancel-safe".

Druse's cancellation model is the opposite: `nbio.remove` is **explicit, final,
and panics off-thread** (§4.2). Importing drop-cancellation semantics would be a
regression in the one area this project has been most careful about.

### B2 — Thread-per-core works, and its weakness is exactly our handler model

Glommio reports **p99 down as much as 71%** against M:N runtimes on the same
workloads. Seastar/ScyllaDB get their gains by removing locks and cache-coherence
traffic entirely.

The universal trade-off: **no work-stealing, so an overloaded shard is not
rescued.** Balance is a design obligation, handled by static partitioning.

> This is precisely the tension §6 arm F identified: a synchronous handler that
> blocks stalls its whole shard. The external evidence confirms the weakness is
> intrinsic to the model, not an implementation detail we could engineer away.

### B3 — The decisive finding: the speed is available WITHOUT a runtime

| Feature | Kernel | Effect |
|---|---|---|
| `IORING_SETUP_SQPOLL` | 5.3 (unrestricted 5.11+) | kernel thread polls the SQ — **no `io_uring_enter` per operation** |
| `DEFER_TASKRUN` + `SINGLE_ISSUER` | 6.1 | batch completions under application control |
| `COOP_TASKRUN` | 5.19 | stop forcibly interrupting userspace |
| registered buffers / files | 5.1 | remove per-operation setup |
| `IORING_OP_SEND_ZC` | 6.0 | zero-copy send |

The reported result of SQPOLL in an echo server is **zero syscalls per request** —
*"nearly no syscalls are ever performed"*.

**Corrected 2026-08-03 after audit finding B.3.** The first draft said *"our
measured problem is ~5 `io_uring_enter` per request"*. **That number was retired
on 2026-07-25.** The default path does **0.160 per request** — the dedicated
acceptor cut it 31× — so the target SQPOLL would attack largely no longer
exists. Citing the pre-fix figure as "our measured problem" while §1.2 of the
same document described the fix was internally inconsistent.

**And this tree has already analysed SQPOLL, more pessimistically than the
external research.** `perf-wp-multishot-scanner.md:72`: it *"removes the submit
enter, but nbio still enters for `wait_nr>0` completions … would need pairing
with busy-poll reaping, and burns a full core"*. On a four-core budget with two
Handler lanes, burning a core for a poller is not a free lever.

So the honest status of this block: **the external evidence is real and the
local target has moved.** Registered files/buffers and `SEND_ZC` remain
untested here and remain plausible. Any syscall-lever track has to be
re-derived against the current code before it is offered as a path — the first
draft offered it against a problem the tree had already solved by other means.

### B4 — Go-style goroutines are out of reach, structurally

Growable stacks need **stack copying with pointer adjustment**, which needs
**stack maps from the compiler** and a GC that knows every frame's pointers.
Asynchronous preemption (Go 1.14) needed the compiler to insert preemption
checks. None of this is runtime code — it is language and GC work.

> Confirms §3: replicating goroutines in Odin means changing Odin.

### B5 — Async Postgres means writing the wire protocol

libpq exposes `PQconnectStart`/`PQsendQuery`/`PQconsumeInput`/`PQisBusy`, but
driving it fully non-blocking is impractical — Diesel concluded async over libpq
could not be done *efficiently*. **`tokio-postgres`, `sqlx` and Go's `pgx` all
speak the PostgreSQL wire protocol directly instead.**

Cancellation is worse than expected: `PQcancel` is a *request* on a separate
connection, with no guarantee it arrives before the query completes.

> **Confirms the §5 warning as fact.** "Async Druse" implies "write a PostgreSQL
> protocol implementation in Odin" — a second project of comparable size, or the
> runtime's speed never reaches the application.

### B6 — The budget

Tokio: started ~2016, **1.0 in January 2021** — four to five years of active
development, dozens of contributors, **several complete scheduler rewrites**.
Seastar: from 2013, a dedicated commercial team. Both still surface production-only
bugs — lost wakeups, zombie tasks, starvation.

### B7 — The adversary is strong

nginx and HAProxy scale with fixed worker processes + `SO_REUSEPORT` and an
epoll loop each — no M:N scheduling. fasthttp reaches its numbers through
allocation discipline, not a custom runtime. And most pointedly: a **simple C
server using io_uring with SQPOLL and linked SQEs achieved zero syscalls per
request while keeping a straightforward synchronous structure.**

---

## 7. What the research must answer

Mapped to the blocks the owner is searching, so results land in the right slot.

**All blocks returned on 2026-08-03. The answers are in §6b; this table records
what each one did to the decision.**

| Block | Question | Answer | Consequence |
|---|---|---|---|
| **0** | is suspension implementable? | **no, and never will be** — *"Odin will NEVER do this"* | **arms C and D closed** |
| **1** | what of Tokio is portable? | almost nothing without `async fn`; drop-cancellation is a known design wound | stop using Tokio as the model |
| **2** | does share-nothing hold under uneven load? | gains are real (p99 −71%) but **no work-stealing rescue** | arm E viable, arm F's blocking problem confirmed intrinsic |
| **3** | can flags close the gap without a runtime? | **SQPOLL reports zero syscalls/request** — and was never tested here | **the speed motivation may dissolve; test it first** |
| **4** | what needs compiler/GC support? | growable stacks, stack maps, preemption | goroutines in Odin = changing Odin |
| **5** | must we reimplement the wire protocol? | **yes** — tokio-postgres, sqlx and pgx all do | a second project of the same size |
| **6** | what did it cost? | Tokio ~5 years, dozens of people, several rewrites | the budget line |
| **7** | did anyone go fast without a runtime? | **yes** — nginx/HAProxy/fasthttp, and a C io_uring server at zero syscalls/request | the adversary must be beaten with numbers first |

**Blocks 0, 3 and 5 decided viability, and all three point the same way:** the
runtime is buildable only in a shape that changes the product, its speed
rationale is untested against a cheaper lever, and its payoff is gated behind a
second project.

---

## 8. Abandonment criteria, written before the answers arrive

Following the R3 rule — *a track may end in "not doing it"* — these are the
conditions under which this study should conclude **no runtime**:

1. **Block 0 returns no viable suspension mechanism** and thread-per-core (arm
   E) measures no better than the shipped arm A.
2. **A reproducible two-box measurement shows the current framework within ~20%
   of the fasthttp class.** At that point the remaining gap does not pay for a
   runtime, and the honest work is elsewhere.
3. **Block 3 shows io_uring configuration and batching close most of the gap**
   with the synchronous model intact.
4. **Block 5 shows async DB requires a wire-protocol reimplementation** and the
   owner declines that second project — because a runtime whose speed cannot
   reach the application is a cost with no delivery.
5. Arm B (worker pool, no runtime) reaches the same latency and throughput
   targets with materially less machinery.

Any of these is a legitimate end. None of them is a failure of the idea.

---

## 8b. Recommendation, 2026-08-03 — revised for the corrected objective

**Take ownership of the I/O layer. Decide on the runtime afterwards, with the
code in hand.**

This is not "no runtime". It is the observation that **the first step is the
same either way**, and that it is the step that unblocks the limitation the
owner most needs removed.

### The reasoning

1. **Of the six declared limitations, a runtime clearly removes two** —
   platforms and the vendor fork (§0.1). It does not remove native protocols or
   release policy, and it does not genuinely remove handler-fault containment
   (§0.2).
2. **The two it does remove are both "we do not own the I/O layer"** (§0.3).
3. **The limitation that hurts most in production — a handler fault taking the
   whole process — needs an address-space boundary, i.e. worker processes.**
   That is R3-WP10; ADR-051 already measured that resources are not the
   obstacle; it is blocked on `nbio` being unable to adopt a socket it did not
   create.
4. **So one missing entry point blocks the most valuable limitation removal,
   and owning that layer is also step one of any runtime.** Two tracks, one
   prerequisite (§4.5).
5. **Nothing about that first step commits us to the state-machine API** that
   would change what Druse is (§3.2). It can be stopped, extended, or turned
   into a full runtime later, on evidence.

### The order that follows

| Step | Work | Removes / unblocks |
|---|---|---|
| **0** | **Finish R2** (WP04–WP08). Added 2026-08-03 after audit finding I.2: the first draft treated it as a standing obligation in prose but left it out of the sequence, which is where a sequence gets ignored | defines the envelope everything else is measured against |
| **1** | **Own the I/O layer**: vendor `core:nbio` or upstream a socket-adoption entry point. Policy decision first, code second. | prerequisite for 2, 4, 5 |
| **2** | **R3-WP10 stage 3**: implement a worker-process arm, run the fault campaign with its **negative control in N=1 going red** | **limitation 1** — the worst one |
| **3** | **R3-WP02**: reconcile or retire the 43 divergences | **limitation 5** |
| **4** | **Backend abstraction**, with a second backend proving the seam is real — and **choose it for double duty**: kqueue/macOS pays for the seam *and* advances limitation 4, so step 5 deciding "no runtime" cannot throw the work away | **limitation 4** |
| **5** | **Decide on the runtime**, holding steps 1–4 | limitation 2, if the cost is then acceptable |
| **6** | **R3-A release policy**; **R3-E protocols** by requirement | limitations 6 and 3 |

### The re-measurement cost, which the first draft did not declare

**Added 2026-08-03 after audit finding I.1.** Step 0 produces soak, capacity and
canary evidence for **N=1**. Step 2 adopts worker processes — **N>1** — and
R3-WP10 already requires the resource budget to be redone for N>1. By the same
logic, soak and capacity describe a different topology too.

So one of two things is being bought, and the plan must say which:

- **workers ship opt-in**, the default profile stays N=1, and the R2 envelope
  survives intact — at the price of limitation 1 remaining in the *default*
  supported profile until a later promotion; **or**
- **workers become the default**, and part of the R2 campaign is re-run for N.

**Recommended: opt-in first.** It keeps R2's evidence valid, makes containment
available to anyone who wants it, and defers the re-campaign until there is
production experience to justify it. Promotion to default is then its own
decision with its own evidence, rather than a cost hidden inside step 2.

**Steps 2, 3 and 4 are each independently valuable, each removes a declared
limitation, and none requires committing to a runtime.** If after them a runtime
still looks necessary, it will be designed against a codebase that owns its own
I/O — which is a far better position than designing it now.

### Where the performance work belongs

Not on this path. §1 stands as written: if throughput matters later, the
untested syscall levers (`SQPOLL`, registered files/buffers, `SEND_ZC`) are the
cheap first move, and the two-box measurement is owed regardless because our own
numbers disagree by 3× (§1.2). **It is a separate track and it does not gate
anything here.**

### And the standing obligation

**R2 is not finished.** WP04 through WP08 remain, the host is qualified and idle,
and the pre-registration is committed. None of the work above is admissible as
a reason to leave a readiness gate half-open — R2 defines the envelope that all
of these limitations are measured against.

## 9. What this study will contain when complete

- the decision, with an ADR;
- the arm chosen, or the recorded reason none was;
- the architecture at a level someone else could implement;
- the integration contract: arena and `Context` lifetime, cancellation across
  suspension, shutdown/drain, the C-01 inventory delta, and the public API
  surface — if any — with its guardrail review;
- cost in person-months, with the sources for the estimate;
- the limitations the runtime does **not** remove, named explicitly (fault
  containment, platform, protocol);
- rollback: how a Druse with the runtime returns to arm A without a rewrite.

---

## 10. Open questions for the owner

1. **Is the goal throughput on a trivial route, or latency under real
   application work?** They point at different arms. `/ping` numbers have driven
   this discussion so far, and no application-shaped workload has been measured
   under contention.
2. **Is the two-box measurement authorized before the design work?** §1.3 argues
   it is a precondition. It needs a second small instance in the same subnet.
3. **Does a public async API surface enter the product**, or is the runtime
   purely internal? `sync-async-evaluation.md` warns: *"Not expose futures/tasks
   only because the backend internally changed."* This is a G5 decision with
   ledger, ADR and guardrail consequences.
4. **Do we take ownership of `nbio`?** §4.5 shows two tracks blocked on the same
   missing entry points. Upstreaming, vendoring, or neither — but decided once,
   deliberately, rather than discovered again by a third track.

---

## 11. Audit corrections applied, 2026-08-03

An adversarial audit of this document
(`planning/runtime-feasibility-audit-2026-08-03.md`) was commissioned to break
it. Its verdict was that the recommendation survives and is strengthened, and
that nine corrections were required before the document could be a basis for
decision. All nine are applied, and each is marked in place rather than
silently rewritten:

| # | Correction | Where |
|---|---|---|
| 1 | The 3× contradiction was mine — the two figures describe different code, and the repository had already resolved it | §1.2, §1.3 |
| 2 | Two "settled" items describe retired code; the `DEFER_TASKRUN` refutation downgraded to untraceable provenance | §1.1 |
| 3 | The measured problem is 0.160 enters/request, not ~5; the tree's own pessimistic SQPOLL analysis added | §6b/B3 |
| 4 | Arm F's blast radius is the *same* as today's, not worse; it dies on the ownership bill instead | §6 |
| 5 | Dossier provenance recorded with per-file hashes, so the twelve citations are auditable | `planning/runtime-tina-dossier-provenance.md` |
| 6 | Row 1 is "removable only at the price of row 2"; the evidence that would reopen it recorded | §0.2 |
| 7 | Two omitted limitations added; row 4 downgraded to "opens the way" | §0.1 |
| 8 | R2 sequenced as step 0; the N=1 → N>1 re-measurement cost declared and decided | §8b |
| 9 | The normative divergence in `supported-profile.md` raised as its own item | below |
| — | *(also applied, audit finding G, not on the required list)* The wire-protocol necessity de-overstated; psycopg3 recorded as counter-example; "comparable size" withdrawn | §5 |

### 9 — a normative divergence, raised and not resolved here

The audit found, outside this study's scope but inside its duty to check the
limitations it reasons about: `docs/supported-profile.md:46–49` says that on
lane saturation the acceptor closes the socket *"without writing an HTTP
response"*, while the adoption report and the gate's C-05 suite record a **full
503 with `Retry-After: 1`**.

**Two normative documents disagree about what the server does under saturation.**
One of them is out of date, and applications are written against both. This
study does not resolve it — it is a product question, not a runtime question —
but it must not sit in an audit appendix: it needs its own item, its own
measurement of the current binary, and whichever document is wrong corrected.

R2-WP04's smoke touched the same behaviour from the other side: the generator
sees `eof_on_fresh_conn`, which is consistent with *close without a response*
and not with a 503. That is a data point, not a resolution.
