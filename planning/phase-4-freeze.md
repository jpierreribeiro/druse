# Phase 4 — Freeze

**Date: 2026-07-21. Toolchain:** the pinned commit in `odin-version.txt`
(`819fdc7`); the gate refuses any other. **Gate:** `build/check.sh` exits 0.
**Authority:** the **ADR-029 delegation**, which resolved WP56 as *"delegated to
the gate, WP38-style: freeze if and only if every gate is green, every ledger
amended, seeds and soak results recorded. Any breach stops and goes to the
owner."*

**There is one breach-shaped item and it is not a breach: two work packages are
recorded as NOT DELIVERED with their reasons** (§5). The delegation's condition
is that criteria are met, not that every box is ticked — and a package that
records why it could not be built is a criterion met, while one that ships a
knob that lies is not.

---

## 1. The ledger diff

| | Phase 3 froze | Phase 4 adds | Total |
|---|---|---|---|
| application | 50 | +5 | **55** |
| test-support | 2 | 0 | **2** |
| union | 52 | +5 | **57** |

| Symbol | Kind | WP | Freeze amendment |
|---|---|---|---|
| `stop` | proc | 44 | 14 |
| `client_ip` | proc | 48 | 16 |
| `trust_proxies` | proc | 48 | 16 |
| `secure_headers` | proc | 49 | 17 |
| `refused_connections` | proc | 50 | 18 |

**Plus three FIELDS on existing types, which cost no name:**
`Limits.max_request_time` (WP46, Amendment 13), `Limits.max_connections` and
`Limits.reserved_conns` (WP47, Amendment 15), and
`Recorded_Response.headers` (WP49, Amendment 17 — D-14.3 decided).

**+5 for the phase that made the framework deployable.** Deadlines, bounded
admission, stop, trusted proxies, security headers and an observable drop policy
cost five names between them, because four of the seven capabilities arrived as
fields on a struct that already existed.

**Rejected and staying rejected:** a `max_drain_time` field (WP44 — it could not
be made to bound anything, and a knob that lies is worse than an absence), CIDR
parsing for trusted proxies (WP48 — a wrong mask trusts a network you did not
mean to; a wrong prefix only fails to trust one you did), CSP and HSTS in the
core (WP49 — pure policy, and TLS is the proxy's), a cookie API (nothing to
secure), in-process TLS, CORS, uploads, static files, WebSocket and streaming.

---

## 2. The three deficiencies, and what happened to them

Phase 4 opened with a definition: **a deficiency is a gap between what the
framework CLAIMS and what it DOES.** By that standard the tree had exactly
three.

| # | Deficiency | Status |
|---|---|---|
| 1 | **No deadline of any kind.** A slow client held a connection forever | **CLOSED** — `Limits.max_request_time`, 30 s default (WP46) |
| 2 | **No way to stop.** The only shutdown was a kill | **PARTLY CLOSED** — `web.stop` ships; **the drain has no deadline** (WP44) |
| 3 | **No bound on connections** | **CLOSED** — `Limits.max_connections` with a reservation (WP47) |

**Deficiency 2 is the honest one.** `stop` exists, admission stops, cleanup runs
exactly once — and a client holding a connection can still delay the drain
indefinitely. The supervisor's kill remains the real deadline, and
`docs/operations.md` says so in those words rather than implying otherwise.

---

## 3. What the phase found that nobody was looking for

**Two live defects, both found by instruments built before the search.**

**Slowloris (WP41).** Every case in the WP9 corpus was a COMPLETE transmission.
None asked what happens when the bytes simply stop. They stop in the fault lab,
and the server held the connection until the LAB gave up — one socket, no
bandwidth, indefinitely. WP46 closed it.

**Keep-alive was broken for every GET (WP45).** The corpus proved that a BAD
request retires a connection; **nothing proved that a GOOD one preserves it.** A
server that closed after every response passed the entire existing suite — and
did. The cause was one upstream line: `_body_length` set `_body_ok = false` at
entry and a request with no `Content-Length` returned through the SUCCESS path
without correcting it, so every GET looked like a failed body read. **No
`Connection: close` was advertised**, so clients paid a TCP handshake per request
while HTTP/1.1 promised persistence.

**Both are shapes rather than oversights**, and both are worth stating as
lessons: a suite that only tests refusal cannot see a broken acceptance, and a
corpus of complete inputs cannot see an incomplete one.

---

## 4. The three ledgers, amended

**Claim ledger** gains **C-10** (limits configurable, both transports enforce
the same body cap), **C-11** (a request that never finishes arriving is closed)
and **C-12** (admission bounded, with a reservation). Each carries a negative
control, and C-11's is the sharpest in the project: **the same laboratory
asserts the OLD behaviour against a server with no deadline configured and the
NEW behaviour against one that has it, side by side in one suite** — so "the
deadline works" cannot be satisfied by a server that closes everything.

**Capacity ledger**: `concurrent connections` moved from *"not bounded by this
framework"* to a bounded, configurable row; `accept queue` and `inbound header
count` remain unbounded and say so; the read-deadline row exists at all for the
first time. **The list of unbounded things is shorter than it was, which is what
a production phase is supposed to do to it.**

**Lifetime ledger**: unchanged. Phase 4 introduced no new borrowed value —
`client_ip` returns a request-scoped view over storage the ledger already
covers, and `refused_connections` returns an integer.

---

## 5. What was NOT delivered, and why

**Recorded as findings rather than as gaps, because each has a reason that
outlives the package.**

**The drain deadline (WP44, spec §1.3 obligation 3).** Bounding the drain loop
is not sufficient: the `nbio.run()` that follows it waits on every pending
operation, and a connection a client holds open has one. Closing those hard at
the deadline did not help. **The measured result was a drain that never
terminated — worse than the unbounded wait it was meant to replace.** Withdrawn.

**The whole-system allocator audit (WP54).** The serve path does not run under
an allocator this process controls: the vendored server owns per-connection
arenas and a per-thread temp allocator, and `web.serve` hands it a `Config`.

**A fuzzer (WP52).** What one needs and this project does not have is a
corpus-minimising harness and a crash oracle beyond "the process died". The
fault lab's generator is deterministic on purpose — a fuzzer's value is finding
inputs nobody imagined, and its cost is findings nobody can replay.

**A real soak (WP53).** 800 requests over 8 keep-alive connections, zero
failures. That is *load*, not soak, and the document says so. RSS was not
usefully captured and is recorded as a **broken measurement** rather than as an
improvement, which is what the arithmetic would otherwise have claimed.

**Three of these point at one boundary.** WP44's drain, WP46's containment
result and WP54's allocator seam all stop at the same place: **the operation
lifecycle of the vendored event loop.** Three independent packages saying one
thing is evidence, and it belongs to **ADR-033**, which this phase closed and
then REOPENED on WP44's counter-evidence — by the trigger the ADR wrote for
itself.

---

## 6. Mutation suites, all re-run

Fifteen suites green at this commit. **Re-running them found three broken
controls, which is the entire argument for the step.**

| Suite | Result |
|---|---|
| WP16, 17, 18, 19, 20, 21, 22, 24, 30, 36, 37, 39 | PASS |
| **WP23** | PASS — **probe re-anchored**: WP49 inserted the security-header block between `count := n` and the request-ID block, so an anchor spanning both stopped matching. Now anchored on the request-ID block alone. |
| **WP25** | PASS — **control re-aimed**: it deleted the `concurrent connections` unbounded row, and WP47 had BOUNDED that row. The control now targets one that is still genuinely unbounded, and the freeze gate's own stale list was amended with it. |
| **WP41** | PASS — **count corrected**: the probe asserts exactly how many sites report "held open", and WP45 added a third. It caught that immediately rather than mutating two of three and reporting a hole. |

**Every one of the three broke because the tree improved.** That is the healthy
failure mode for a control, and it only shows up if somebody re-runs them.

---

## 7. Performance

**No regression, and no new claim.** The WP26 harness's tolerance on this
machine is **13,821 basis points — 138%**, re-verified at the Phase-3 freeze, so
this phase reports **survival and correctness rather than percentiles**: 800
requests over keep-alive connections, 400 × 200 and 400 × 201, zero failures.

**The one performance change worth naming is not a measurement.** Keep-alive did
not work before WP45, so every request paid a TCP handshake. Fixing that is
worth more than anything this instrument could have measured — and it is
recorded here rather than as a benchmark, because the honest evidence is the
defect and its fix, not a number from a 138% band.

---

## 8. Freeze conditions

* [x] `build/check.sh` exits 0 on the pinned toolchain.
* [x] 55 application + 2 test-support = 57, byte-identical to the snapshot.
* [x] Every new symbol carries a G-09 evidence row (amendments 13–18); every
      citation resolves.
* [x] The three ledgers amended: claim (+C-10, C-11, C-12, each with a negative
      control), capacity (connections bounded, deadline row added), lifetime
      (unchanged, and stated as unchanged).
* [x] All fifteen mutation suites re-run — **three repaired**.
* [x] Load results recorded, with what they do NOT measure stated.
* [x] Operations documentation shipped (`docs/operations.md`), including a
      known-limitations section that does not flatter the framework.
* [x] Everything not delivered is recorded with its reason (§5).

**One matter goes to the owner rather than being decided here: ADR-033 is
OPEN.** Whether Druse eventually owns the HTTP/1.1 connection layer is now
backed by three independent findings, and it is the largest question the project
has. A release or a tag remains a reserved matter as it always was.
