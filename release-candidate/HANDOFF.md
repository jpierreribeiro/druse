# Handoff — 2026-07-30

Read this first. It replaces the previous handoff.

Working directory is `/home/jp/Desktop/uruquim-odin` (the local rename to
`druse` has NOT been done — see "still open"). Every command below assumes you
`cd` there first; the session's own cwd is elsewhere and nothing should ever be
written to it.

---

## Where things stand

The performance investigation the owner asked for is **finished and recorded**.
It answered "escala bem com requisições simples, mas perde nos casos de uso
reais" with numbers, found that two published numbers were wrong, corrected
them, built a fix for the real gap, and measured it.

Five reports were written today. Read them in this order — each corrects or
extends the one before:

1. `docs/reports/2026-07-30-soak-failure-attribution.md` — the 1,085 soak
   failures are acceptor saturation refusals, proven by a six-arm experiment
   with pre-registered predictions.
2. `docs/reports/2026-07-30-open-loop-application-matrix.md` — the first
   matrix, **with a published correction**: its `/json/medium` row is withdrawn.
3. `docs/reports/2026-07-30-nested-json-knee.md` — the honest JSON number.
   2.3× below the knee, ceiling ~20,800/s. Supersedes the withdrawn row.
4. `docs/reports/2026-07-30-encode-profile.md` — the encode path profiled for
   the first time. This is the map for all remaining optimisation work.
5. `docs/reports/2026-07-30-encode-type-gate.md` — a fix, measured:
   −21.2% p50, +27.7% ceiling, correctness proven by mutation.
6. `docs/reports/2026-07-30-six-framework-matrix.md` — Druse against Axum,
   Fiber, Gin, net/http and Fastify.

Also written: `planning/diagnosability.md` (the normative standard) and
`planning/diagnosability-audit.md`.

**All data is committed.** Nine commits are local and unpushed; `git status` is
clean under `web/ bench/ build/ ops/ planning/ docs/ tests/`. Nothing is waiting
to be collected from anywhere. No process is running locally or on the
benchmark host.

---

## Two errors I made today, so you do not repeat them

**I published a 700× figure that was a queue depth reported as a service time.**
The document Druse emitted was 960 bytes larger than the peers' (Odin renders
`f64` with sixteen decimals), and the rate was past Druse's knee. Both confounds
were already named in the 2026-07-25 study; I reintroduced them.

**I then claimed float rendering costs 50×**, which was the same knee artifact
seen from the other side. It costs 3% at 5,000/s, 6% at 10,000/s.

The instruments now refuse both mistakes on their own:
`summarise-openload-matrix.py` flags rows whose servers emit different byte
counts, `build/check_bench_controls.sh` proves it flags, and the sweep and A/B
harnesses print which rates are below the knee. **Trust the flags over your own
reading of a latency column.**

---

## Question 1 — can the saturation refusals be studied and fixed?

Yes, and they split into two questions that should not be confused.

**(a) Capacity: already answered, not a defect.** The six-arm experiment showed
**16 lanes → zero failures and zero refusals, in both repeats**, on the same
hardware. `ListenOverflows` and `ListenDrops` were zero in every arm, so the
kernel accept queue never overflowed — the refusal is Druse's own admission
decision, and `docs/operations.md` documents it: `max_connections` 1024, "the
connection is closed at accept, not queued".

**(b) The open question is the auto-sizing rule, and it is a real one.**
`max_handlers` auto-resolves from CPU count, bounded to 4..32. On the pinned
4-CPU server that yields 4 lanes — and 4 lanes is exactly where the refusals
appear. Sixteen lanes on the *same four CPUs* eliminated them completely. That
is evidence the rule is wrong for this workload: a lane doing JSON encode is not
CPU-saturated the whole time it holds its slot, so sizing lanes to CPUs
under-provisions admission. **Whether the auto rule should change is
unmeasured, and it is the most valuable unstudied thing in this area.**

**(c) A second, independent question: the shape of the refusal.** A refused
client sees an EOF on a fresh connection with no HTTP response — 93 of 129
failures carried that signature. From the client's side that is
**indistinguishable from a crash**. The server knows
(`web.stats().saturation_refusals`); the client cannot. Whether the acceptor
should write a `503` with `Retry-After` before closing is a design question that
would need an ADR — `docs/operations.md` currently states the refusal "must
never be described as a 503 response" precisely because today it is not one.
Do not change this quietly; it is a wire-behaviour change.

**Proposed order: (b) then (c).** (b) is an experiment against an existing knob
and could change a default; (c) is a spec amendment.

---

## Question 2 — is encode the last optimisation step?

It is the **largest remaining one**, and unlike everything before it, the whole
ladder is now quantified. From `2026-07-30-encode-profile.md`:

| Cost | Share of encode self time | Status |
|---|---:|---|
| Second validation pass | **~25.5%** | **fix built and measured, NOT adopted** |
| Rune-by-rune string writing | **~25.7%** | **untouched — the biggest lever left** |
| Builder growth | 10.7% | **measured and REJECTED** — do not revive |
| Float rendering | ~6.8% | untouched; fixing it also closes the 5,398-vs-4,438 byte gap |
| RTTI tag lookup | 4.3% | untouched |

**Step 1 — adopt the type gate.** It exists, at `web/respond.odin`, behind
`-define:DRUSE_JSON_TYPE_GATE`, defaulting **off**. It is measured (−21.2% p50,
+27.7% ceiling), its safety is proven in both directions (blinding the walk to
floats turns `wp6-public-surface` red on the exact assertion that a non-finite
token must not reach the wire), and the full gate is green with it in the tree.
Adopting it means flipping the default, and that is a work package: the freeze
ritual, a decision on whether the conservative walk's coverage keeps the promise
in `docs/errors.md`, and the gate.

Two guardrails already bit this code and both were right — the constants must
stay `@(private)`, and the walk must **not** recurse through
`reflect.Type_Info_Pointer` (R-13 forbids web/ reading through a pointer payload
until ADR-003 is amended; pointers fall through to the conservative `true`).

**Step 2 — the string writer, and it is the biggest one left.**
`io::write_quoted_string` decodes every string into runes and writes them one at
a time through `write_encoded_rune` / `write_escaped_rune` — 25.7% of self time
across four symbols. The standard fix is an ASCII fast path: scan for the first
byte that is `< 0x20`, `"`, `\` or `>= 0x80`, copy everything before it in one
move, and fall back to the slow path only from there. Go's `encoding/json` does
exactly this.

**The obstacle is location, not difficulty.** This code is in the Odin
toolchain's `core:encoding/json` and `core:io`, which the project pins but does
**not** vendor — `vendor/` holds `nbio`, `odin-http` and `uring_buf_ring` only.
So there are three routes and the choice needs the owner:

- vendor `core:encoding/json` as the project already vendors three others, with
  the WP16 CONTROL 6 mechanism that proves a vendor patch is re-applied;
- write Druse's own quoted-string writer for the marshal path only;
- upstream it to Odin and pin the newer toolchain.

**Step 3 — float rendering** wins twice: ~6.8% of encode time *and* it is the
reason `/json/medium` is not comparable at all. Sixteen decimals for `1.5` is a
formatting choice, not a precision requirement.

**Do not revive builder pre-sizing.** It was measured: +0.9% p50, −2.6%
ceiling, despite holding 10.7% of the profile. The lesson is recorded in the
type-gate report — a symbol's share of a profile is not the gain available from
removing it.

---

## Still open, in the order the owner set

The owner's stated objective order was "2 and 3, then 1": sweep the float route
(done), profile the encode (done), **then cut the tag**.

1. **Confirm the final gate.** The last full run from `db2139a` was launched and
   should be read before anything else: `PASS`/`FAIL`/`ERROR` counts in the
   scratchpad log, or just re-run `bash build/check.sh`. The previous run gave
   155 PASS / 0 FAIL with one error that was a race against my own evidence copy
   (`tar: file changed as we read it`) and which passes standalone.
2. **Push the nine local commits and cut `v0.10.0`.**
3. Then the queue that was always behind the tag: bump the crystals pin and
   `COMPATIBILITY.md` to the tag commit; `druse-board`; `druse-miniature`
   (blocked on the two merges); rename the local directory `uruquim-odin` →
   `druse` with `core.hooksPath` repointed; the two untracked security reports
   in `docs/reports/`; Phase D's audit of the 110 suites against the three
   diagnosability rules.

## Decisions waiting on the owner

- **The benchmark host is at 95% disk, 1.7 GB free.** `/home/ubuntu` holds
  ~18 GB of raw run data across `druse-experiments`, `mx6`, `mx2`,
  `druse-matrix-out`, `sweep`, `sweep-float`. Everything needed for the reports
  is already committed as per-run reports (748 KB). Deleting the raw streams is
  the owner's call, not mine — but the next benchmark campaign will not fit.
- **Which route for the string writer** (vendor / own writer / upstream).
- **Whether the acceptor should answer 503 before closing** — a wire-behaviour
  change needing an ADR.

## Facts that will save you time

- `@(static)` in an Odin parametric procedure is **per-instantiation**, verified
  empirically. That is what makes the type gate one integer per type, for ever.
- `base:intrinsics` resolves a field type only by name
  (`type_field_type($T, $name: string)`); there is no field-type-by-index, so a
  compile-time struct recursion is genuinely inexpressible. The runtime walk is
  the way around it.
- A Druse server that cannot bind **returns from `serve()` with status 0 and
  logs nothing** (druse#152). "The process is gone" is the only external signal
  a start failed. Every harness here now aborts on it; the first version of the
  A/B script recorded 100,000 `dial_refused` per run as data because it did not.
- `pgrep -f X` inside a command whose own line contains `X` matches **itself**.
  This produced false "still running" readings all day and left four wait loops
  hung for hours. Use `ps -eo args | grep -c "[r]un-..."`.
- Never edit a shell script while it is executing — bash reads it incrementally.
