# Phase 5 freeze — the drain closed, the table set

**Status: FROZEN, 2026-07-21, under the ADR-029 delegation.**
**Gate green at every work package. Nothing was left uncommitted and nothing
was left undecided without its reason written down.**

---

## 1. The ledger

| | Phase 4 froze | Phase 5 adds | Total |
|---|---|---|---|
| application | 55 | +7 | **62** |
| test-support | 2 | 0 | **2** |
| union | 57 | +7 | **64** |

The seven: `cors`, `Cors_Options` (WP60), `static`, `Static_Options` (WP61),
`form_field`, `form_file`, `Uploaded_File` (WP63).

**One field cost no name:** `Limits.max_drain_time` (WP59), on the precedent
three of Phase 4's five deliveries set. **One dependency was added:** `web`
gained `core:os`, the first change to `build/phase1-direct-dependencies.txt`
since Phase 1, and the only one this phase makes.

Amendments 19 through 22 in `phase-1-freeze.md` carry the eight G-09 evidences
for each.

---

## 2. What the phase was for, and why it was not the phase the roadmap wrote

The roadmap scoped Phase 5 as *Ecosystem*, gating every item on "a real user
request". **That criterion cannot be satisfied by a project with no users**, and
a rule that can only be satisfied by the state it prevents is a deadlock rather
than a discipline. AMEND-P5-2 waived it for three items and no others.

So the phase did two things: **closed the drain**, which is the only gap a
reverse proxy cannot absorb, and **shipped the table stakes** — static files,
CORS, uploads — because a framework missing all three is a routing library, and
a person arriving from Gin finds that out in week one.

---

## 3. The two defects found, and neither was being looked for

**The drain never terminated, and then it crashed.** WP58 measured what Phase 4
had recorded as one unbounded wait and found three, plus something worse: with
eight idle keep-alive connections the drain did not end at all, and letting
those connections complete killed the process on a freed pointer.

The mechanism was one missing capability. `scanner.odin` discarded the
`^nbio.Operation` that `recv_poly` returns, so every keep-alive connection left
a read that was **unreachable and therefore uncancellable**. That single
discarded pointer produced both failures:

- `nbio.run()` waited on operations whose connection had already been freed —
  the drain that never ended;
- when those reads later completed, `scanner_on_read` dereferenced a
  `^Connection` that `connection_close` had freed — `free(): invalid pointer`.

**Patch 10 is upstream's bug, not this project's**, and it is worth offering
upstream regardless of the January transition. A real deployment with idle
keep-alive clients could hang on shutdown or crash on it. Neither was in
`operations.md`, because neither was known.

**A static mount that silently served nothing.** The first implementation
defended against symlinks by comparing the resolved path against the mount root.
It 404'd *every* file, because `stat` returns an absolute path while the mount
was configured relative. **The corpus caught it; a reviewer would not have** —
the code reads correctly, and the failure is a string comparison between two
things spelled differently. The shipped version refuses symlinks outright
instead: a rule with no arithmetic in it has no arithmetic to get wrong.

---

## 4. What was NOT delivered, and why

Recorded here rather than omitted, on the Phase-4 precedent: a freeze that drops
these rows reads as a phase that delivered everything.

**Streaming, WebSocket, HTTP/2, OpenAPI, templates, database integration.** Out
of scope by AMEND-P5-2, which named three items and explicitly no others. The
demand-driven gate still governs every one of them.

**Large uploads.** WP62 answered OQ-20 and closed it, but the answer bounds the
feature rather than completing it: an upload larger than `max_body` cannot be
accepted at any setting that is not itself a memory problem, because the body is
held whole. Gin spools to disk through `net/http`; this does not spool at all.
Named in `operations.md` §10 in those words.

**Ranges and `Last-Modified` on static files.** Ranges need the partial-response
machinery streaming needs. `Last-Modified` needs an HTTP date formatter linked
into every application, and `ETag` validates as well without one.

**A second transport adapter.** AMEND-P5-3 makes that January's work.

**Ecosystem work.** CE-E3 stands unamended and PR #49 is still a draft, though
AMEND-P5-4 records that its CE-E4 gate opened when WP44 merged.

---

## 5. ADR-033 closes: keep and patch, with the transition as the declared exit

**The third data point arrived and it was contained.** The ADR's own criterion:
WP46's patch stayed contained and closed it; WP44's did not and reopened it. The
boundary was said to run "somewhere between a periodic sweep beside an existing
tick and the operation lifecycle of the event loop".

WP59 ran directly on that second thing — cancelling a pending operation — and
stayed contained: three patch sites, one struct field, one option field, and a
loop that ticks instead of blocking.

**But containment is no longer the deciding argument, and the freeze should say
so.** ADR-033 Amendment 1 removed arm C when `core:net/http` acquired a date:
building a connection layer over six months, to be superseded by one the
language maintains, loses either way. **The ADR closes on A/B — keep and patch —
with the swap as its declared exit rather than as a hypothetical.**

The obligations that follow are already in force and were honoured by every
package this phase: nothing in `web/` learned anything about the backend, the
multipart parser consumes `[]u8` and never touches a socket, static file serving
fills `Outbound` like any other response, and the three drain patches are marked
`DRUSE PATCH — BRIDGE` — expected to be **deleted**, not ported.

---

## 6. Guardrail 3 was violated, measured, and fixed

Worth its own section because the violation was invisible and the fix is a
pattern the next package will need.

Calling the static file server directly from `driver_run` linked `core:os` into
**every** binary. `examples/01-hello-world`, which serves no files, grew by
**20 176 bytes**. The rule it broke is roadmap governing rule 3: an application
that does not use a feature pays zero bytes for it.

The server is now reached through a proc pointer whose only assignment is inside
`static`, exactly as `test_teardown` is under G-11, so the linker drops it — and
`core:os` with it. Measured after the fix:

| | before Phase 5 | after |
|---|---|---|
| `01-hello-world` (uses none of it) | 966 984 | 970 664 |
| `08-table-stakes` (uses all of it) | — | 1 006 080 |

**3 680 bytes** for an application that uses nothing of this phase: the pointer
field, three inline config structs, and nothing executable. The 35 KB difference
between the two examples is the feature being paid for only where it is used.

---

## 7. The mutation controls

**Sixteen control scripts re-run at the freeze. All sixteen green, and none
needed repair.**

That is a different result from Phase 4, where three broke because the tree had
improved, and the difference is worth stating rather than glossing: Phase 4
changed behaviour that existing probes were anchored to. Phase 5 mostly *added*
surface — new files, new symbols, new suites — and touched the shared request
path in exactly two places (`response_headers_finish` and `driver_run`), both by
appending rather than by rearranging. **A green sixteen here is evidence of what
the phase did, not evidence that nobody looked.**

---

## 8. Freeze checklist

- [x] Ledger 62 + 2 = 64, asserted by `build/check_public_api.sh`
- [x] Amendments 19–22 in `phase-1-freeze.md`, each with all eight G-09 evidences
- [x] `build/phase1-public-signatures.txt` updated; struct shapes frozen field-by-field
- [x] `build/phase1-direct-dependencies.txt` updated for `core:os`
- [x] Every new `web/*.odin` carries its `// druse:file application` marker
- [x] Docs parity: every new symbol in `docs/ai-context.md` with a compiling fixture
- [x] `docs/operations.md` §3 and §10 name every new perimeter and every remaining gap
- [x] Eight examples compile against the public surface only
- [x] Sixteen mutation controls re-run, all green
- [x] OQ-20 closed by WP62
- [x] ADR-033 closed; ADR-034 accepted; ADR-033 Amendment 1 recorded
- [x] `build/check.sh` green, exit 0
- [x] Two reserved words released with their reasons: `cors` from the
      later-phase list, `upload` from the future-vocabulary list

---

## 9. What goes to the next phase

**January 2027 and `core:net/http`.** The transition is now the largest item in
the project, and every obligation that makes it cheap is already in force.

**The demand-driven gate is intact for everything else.** Streaming, WebSocket,
HTTP/2 and OpenAPI still wait for a real request. The waiver this phase used
named three items and was written so it could not be stretched.

**Nothing forces a Phase 6 yet.** The framework now has what an application
needs in its first week, a shutdown that terminates, and a documented account of
what it does not bound. The most useful next act is somebody using it.
