# WP112 — joy-of-programming & AI-readability study

**Status: IN PROGRESS, 2026-07-24.** A product gate, not marketing research
(plan §WP112). It measures whether the framework's PUBLIC surface + examples let
independent contributors implement the SAME canonical shape without inventing a
second architecture or reaching into internals (hypothesis 8; G8-6).

The human-contributor condition is reserved to the owner. This document records
the **coding-agent conditions**, run as isolated, independent attempts.

---

## 1. Method

- **Task (T1)** — the plan's "add a validated field through migration, SQL,
  handler and (notification)" cell, made concrete: *add an optional `due_date`
  (nullable `timestamptz`) to tasks — a new immutable migration, the field in the
  task JSON (ISO string or null), accepted on `POST …/tasks`, and settable/
  clearable in `PATCH /tasks/:id` with the same three-state semantics as the
  other patchable fields.*
- **Conditions** — three independent coding agents, each in its OWN isolated copy
  of the board, none able to see the others:
  - **A** — model *sonnet*.
  - **B** — model *sonnet* (A/B are the convergence pair — same everything).
  - **C** — model *opus* (the model-tier axis).
- **Materials given** — the board's own existing code, the reference app
  `crystals/examples/notes`, and the public `druse:web` / `crystals:*` API.
  Reading the framework's INTERNAL source (`core web/`) was disallowed — the test
  is whether the public surface + examples suffice.
- **Success bar** — the build gate must pass (`PASS: druse-board build gate`),
  which structurally enforces **G8-1** (no internal import) and full typecheck
  against the pinned public contracts.
- **Recorded per condition** — files changed; compile attempts; concepts used;
  where the API was unclear / internals were tempting; ownership/type mistakes;
  the hardest part. (The agents self-report these; their diffs are inspected
  independently against §2.)

---

## 2. The canonical shape (the reference the attempts are scored against)

Defined BEFORE the attempts, from the board's existing patterns, so "convergence"
is measured against a fixed target rather than post-hoc. The ideal diff mirrors
the existing `body`/`assignee` handling:

1. **Migration** `0008_task_due_date.{up,down}.sql`: `ALTER TABLE tasks ADD
   COLUMN due_date TIMESTAMPTZ;` / `DROP COLUMN`. Nullable, no default.
2. **Read** — `TASK_COLUMNS` gains `due_date::text` (the `::text` cast pattern the
   board already uses for `created_at`/`updated_at`, so a nullable timestamp
   round-trips as an ISO string); `scan_task` reads it with `pg.row_opt_text`
   (nullable → `Maybe(string)`), at the correct new column index.
3. **View** — `Task_View` gains `due_date: Maybe(string) \`json:"due_date"\``
   (JSON null when the column is NULL — the `Maybe` idiom already used for
   `body`/`assignee_id`).
4. **Create** — `Create_Task` gains `due_date: Maybe(string)`; the INSERT adds the
   `due_date` column and a param that is `pg.arg_null()` when absent else
   `pg.arg_text(v)` (PostgreSQL assignment-casts the ISO text to `timestamptz`).
5. **Three-state PATCH** — `taskpatch.Task_Patch` gains `due_date:
   validate.Patch(string)`; `taskpatch.parse` handles the `"due_date"` key via the
   existing `read_string_patch`; `patch_task` computes a `due_date_mode` via
   `tp.patch_mode` and adds a SQL branch `due_date = CASE $n WHEN 'set' THEN
   $m::timestamptz WHEN 'null' THEN NULL ELSE due_date END`. The **`::timestamptz`
   cast on the set-parameter** is the one genuinely new wrinkle over the existing
   `body` branch (which is already text).
6. *(Optional, canonical-but-not-required)* — validate the string is non-empty
   when set; the notification already fires (`task.update`), so no new notify is
   needed for PATCH.

**Discriminating sub-points** (where attempts are most likely to differ):
- (a) nullable read via `row_opt_text` + `Maybe(string)` vs a non-null hack;
- (b) the `::text` read cast (timestamp → ISO string) — discovered or missed?
- (c) the `::timestamptz` write cast — handled, or does a raw text insert into a
  timestamptz column surprise them?
- (d) three-state added in the PURE `taskpatch` package (correct) vs bolted into
  `board/tasks.odin` (divergent);
- (e) column-index alignment in `scan_task` after growing `TASK_COLUMNS`;
- (f) zero internal imports (enforced by the gate, but did they *try*?).

---

## 3. Results — condition A (sonnet)

**Converged on the canonical shape at ALL SIX discriminating sub-points.**
Build gate **PASSED on the first attempt (0 failed runs)**; G8-1 clean, no
internal import.

| Sub-point | A's result |
|---|---|
| (a) nullable read via `row_opt_text` + `Maybe(string)` | ✅ `row_opt_text(r, 10, ally)`, `Maybe(string)` |
| (b) `::text` read cast (timestamp→ISO) | ✅ `due_date::text`, mirroring `created_at::text` |
| (c) `::timestamptz` write cast | ✅ `$5::timestamptz` on insert, `$11::timestamptz` on patch |
| (d) three-state in the PURE `taskpatch` package | ✅ added to `taskpatch`, reusing `read_string_patch` |
| (e) column-index alignment in `scan_task` | ✅ index 10, params `$10/$11` appended |
| (f) zero internal imports | ✅ (gate-enforced; no attempt) |

- **Concepts used:** `web.body`, param readers, `pg.arg_*`/`row_*`/`row_opt_*`
  (esp. `row_opt_text` for the nullable idiom), `pg.tx_query_one`/`tx_execute`,
  `validate.Patch`/`patch_mode`, the board's `::text` cast + `handler_arena`.
- **Friction it surfaced (unprompted):** the `db/postgres` Crystal has **no typed
  timestamp/date param** — dates go in as bound TEXT cast in SQL (`$n::timestamptz`),
  a convention it inferred from the existing `created_at::text` read side but which
  is **spelled out nowhere**. And **no ISO-8601 validator** exists in
  `crystals:validate`, so a malformed `due_date` currently surfaces as a generic
  **500** (`Query_Failed` → `respond_db_error` default), the same untyped-text gap
  the codebase already accepts. → **candidate friction, pending B/C corroboration.**
- **Honest observation:** positional SQL param numbers (`$10/$11`) and `pg.row_*`
  integer column indices are **silent-failure risks the Odin type checker cannot
  catch** — a typo compiles and fails only at runtime against a live DB (which the
  gate does not exercise). A real note on where the type-safety boundary ends.
- **Hardest part (self-reported):** replicating the three-state precedent
  consistently across the four touch points without drifting; resisting adding
  ad-hoc date validation no other field has.

## 4. Results — condition B (sonnet)

**Converged on the canonical shape at ALL SIX sub-points.** Build gate **PASSED
on the first attempt (0 failed runs)**; G8-1 clean.

- Structurally identical to A and C. Used the same placeholder placement as C
  (`due_date` CASE at `$8/$9`, `id`/`version` renumbered to `$10/$11`).
- **Independently surfaced BOTH findings** A and C did: (1) no
  `arg_timestamp`/`arg_timestamptz` in `db/postgres` — "the public surface never
  shows how to *write* a timestamp column, only how to read one back as text",
  so `arg_text` + `$N::timestamptz` is inferred from convention, undocumented;
  (2) `crystals:validate` has no date/timestamp validator (it lists only
  `not_empty`/`string_length`/`int_range`/`one_of`), so a malformed `due_date`
  fails at Postgres as `Query_Failed` → `respond_db_error` default →
  `web.internal_error` = **500, not 400**.
- Explicitly noted it checked `db/postgres` proc **signatures only**, not
  implementation — i.e. it honored the public-surface constraint and did not open
  `exec.odin`/`internal.odin`.
- No ownership/type mistakes; first compile succeeded.

---

## 6. Convergence analysis & findings

**Independent convergence: 3 / 3, near-total.**

- **All three** produced the canonical shape at **all six** discriminating
  sub-points. The migration (`ALTER TABLE tasks ADD COLUMN due_date TIMESTAMPTZ;`)
  and the `taskpatch` field addition (`due_date: validate.Patch(string)`) were
  **byte-identical** across A, B, C (verified by independent diff, not self-report).
- **All three** built on the **first attempt (0 failed runs)** and imported **zero
  internals** (verified by grep, not just the gate).
- **Only divergence**, and it is cosmetic: SQL placeholder placement — A **appended**
  the new params as `$10/$11`; B and C **inserted** the `due_date` CASE at `$8/$9`
  and renumbered the trailing `id`/`version`. Identical behaviour and column
  semantics; a style choice, not a structural fork. No agent invented a second
  architecture, a `Context` bag, ad-hoc date parsing, or an internal reach-through.
- **Triangulated finding (all 3 independently):** the timestamp WRITE-parameter
  gap and the missing date validator (→ 500 on malformed input). Three independent
  discoverers, two model tiers → recorded as **friction F8-8**, the strongest
  provenance in the ledger.

**Honest qualification.** Convergence was *aided by the board's existing
`body`/`assignee_id` precedent* — a nearly-exact template for a nullable optional
three-state field already lived in the codebase, and all three agents copied it.
So this measures the realistic scenario — *can independent agents extend a
codebase consistently through its established patterns + the public API* — and
answers **yes, strongly**. It is a weaker test of the pure docs-only / greenfield
case (no in-codebase precedent), which the human condition and a from-scratch
task would probe further. The precedent existing is itself evidence the framework
*guides* consistent extension.

---

## 7. Verdict input for WP113

**Hypothesis 8 — "documentation lets a human and a coding agent implement the same
canonical shapes" — SUPPORTED for the coding-agent conditions**, with the
qualification above. Evidence: three independent agents (2× sonnet, 1× opus), in
isolated copies, converged on a byte-identical canonical implementation, each
compiling on the first attempt with zero internal imports, differing only in a
cosmetic SQL placeholder choice. **G8-6 (joy)** — "independent users/agents
complete the canonical tasks from public docs without inventing a second
architecture" — is **met for the agent conditions**; the human contributor
condition remains for the owner.

The study also *produced* a real framework finding (F8-8), demonstrating the
proof-by-use loop works even in the usability instrument: making three agents use
the public surface exposed the same missing capability three times over.

## 5. Results — condition C (opus)

**Converged on the canonical shape at ALL SIX sub-points.** Build gate **PASSED
on the first attempt (0 failed runs)**; G8-1 clean.

- Identical structural result to A: migration `0008`, `taskpatch` three-state via
  `read_string_patch`, `due_date::text` read, `row_opt_text` at index 10,
  `$::timestamptz` write cast, `Maybe(string)` view field.
- **Independently surfaced the SAME friction as A:** the `db/postgres` Crystal has
  no `arg_timestamp` — "the one genuine design decision the public surface does
  not decide for you is how a string reaches a `TIMESTAMPTZ` column"; resolved
  with an explicit `$N::timestamptz` cast, matching the codebase style.
- **Independently made the SAME observation as A:** the positional placeholder
  renumbering is "the one spot where a silent off-by-one wouldn't have been caught
  by the build gate — it needed manual care" (the gate typechecks but does not
  link libpq or run SQL).
- **Only divergence from A** — a cosmetic SQL choice: C inserted the `due_date`
  CASE at `$8/$9` and **renumbered** `id`/`version` to `$10/$11`; A **appended**
  the new params as `$10/$11` and left `$1..$9` untouched. Same behaviour, same
  column semantics — a placement style difference, not a structural one.
- Noted the correct lifetime by construction: `row_opt_text` on the per-handler
  `ally` arena (not `temp_allocator`), copied from the `body` precedent.

---

## 6. Convergence analysis & findings

*Pending — compares A/B/C diffs against §2: did independent attempts converge on
the canonical shape? Which discriminating sub-points diverged? Any new friction
(docs gap, unclear API) becomes a ledger candidate. Any internal-import attempt
is a G8-1 finding.*

## 7. Verdict input for WP113

*Pending — hypothesis 8 (docs let independent agents implement the same canonical
shape) is supported / qualified / falsified, with the evidence above.*
