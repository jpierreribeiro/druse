# R2 execution notes — methods, failures, and what they cost

**Status: OPERATIONAL RECORD, 2026-08-03.** Not a plan and not evidence. It is
the thing a `git log` cannot tell you: what went wrong while executing R2-WP02,
WP04 and WP06, which of it was the product, which was the instrument, and which
was the person driving.

Written because the expensive part of this session was not the code — it was
rediscovering traps, and half of them were mine.

---

## 1. The method that produced everything worth keeping

**Measure before concluding, and record the refuted hypothesis.**

Three times a confident explanation was wrong and the measurement corrected it.
In every case the corrected version was more useful than the original guess
would have been if it had happened to be right.

| Hypothesis | What measuring showed |
|---|---|
| "The burn-in's RSS slope is the fault injections" | Peaks *do* land in the same second as the slow-reader injections (24 × 1 MiB = the exact peak height) — **and removing those windows moved the slope only 2,328 → 2,066 KiB/h.** Real, and not the cause. The actual answer was in the median per quarter: 5,920 → 7,184 → 7,746 → **7,744**, an allocator saturating |
| "Our own throughput numbers contradict by 3×" | `git show 44a169f:vendor/odin-http/server.odin` has **zero** occurrences of `DRUSE_DEDICATED_ACCEPT`. Two measurements, two different codebases, six hours apart. No contradiction — I had assumed from today's flag without checking history |
| "A blocking handler under thread-per-core is strictly worse than today" | Since the dedicated accept a connection is lane-affine for its whole life, so **today already has the same 1/N blast radius.** The comparison was false |

**The discipline that made this work:** write the hypothesis down *before*
testing it, so being wrong is visible instead of quietly edited away. Every one
of the three is recorded in the tree with its correction next to it.

## 2. The single highest-leverage habit

**Run the mutant.** A control that has never been seen red is a control nobody
has tested.

It caught real problems every time it was applied:

- deleting the physical-core refusal from `preflight.sh` — the mutant case went
  red *for the wrong reason* at first, which is how I learned the assertion
  needed to name the cause, not just the refusal;
- reverting the `SECURITY.md` patch count — two mutants, one for the marker and
  one for the prose, each red with its own message;
- disabling criterion 18 in the analyser — negative control 12 went red
  immediately;
- restoring the F-005 silent close — the corpus went red **on the status being
  absent**, which is the assertion that matters, not on some neighbouring check.

**And once it exposed a design flaw in the test itself.** The WP9 corpus outcome
`Rejected` *permits a bare close* (D6). For F-005 that permission **is the
defect** — a case written against `Rejected` would have been green on the
vulnerable server. That needed a new outcome, `Rejected_With_Status`. A test
that cannot fail on the bug is worse than no test, because it reads as coverage.

## 3. Failures on the campaign host, and how each was handled

### 3.1 `pkill -f` killed my own SSH session. Twice.

```bash
ssh host 'pkill -f run-soak.sh'      # the ssh command line CONTAINS "run-soak.sh"
ssh host 'pgrep -f "soak/bin/server"' # so does this one
```

The remote shell's own command line matches the pattern, so the process kills
itself. Exit 255, connection dropped, and the second time I had "fixed" it with
the bracket trick (`[r]un-soak`) — which does not help when a *different* part
of the same command still contains the literal string.

**Fix:** stop passing process patterns inline. Write the script to a file, `scp`
it, run it. Or wait on a **PID** (`while kill -0 $PID`), never on a pattern.

### 3.2 `mv` into an existing directory nests instead of replacing

The ladder did `mv "$BASE/soak" "$OUTDIR/burnin-$verdict"`. The second burn-in
also failed, so the destination already existed — and the artefact landed at
`burnin-FAIL/soak` while `burnin-FAIL/` still held the first one.

**This nearly produced a wrong finding.** I read `burnin-FAIL/` for the health
failure and found `errors=0`, which contradicted the verdict. The data was
right; I was reading the previous run.

**Fix:** timestamp every destination. `burnin-FAIL-063252`. A directory name
that can collide will collide, and the failure mode is silent misreading rather
than an error.

### 3.3 `set -e` and commands that exit non-zero *by design*

```bash
bash "$SOAK/smoke.sh" "$report" >/dev/null 2>&1   # exits 1 — that is the test
```

Under `set -euo pipefail` this kills the control script with **no message at
all**: exit 1, empty stderr, nothing to diagnose. Cost about ten minutes twice
before the pattern was obvious.

**Fix:** `|| true` on every deliberate-failure invocation. And note that
`grep -q X && fail "..."` is *safe* — bash exempts commands before the final
`&&` — which is why some lines need the guard and others do not.

### 3.4 Backticks in a commit message heredoc

```bash
git commit -m "...`odin version` answered perfectly..."
```

The shell executed `odin version` and spliced the output into the message, then
`git` read the rest as pathspecs. Two commits landed with mangled messages
before I switched to `-F file` with a quoted heredoc (`<<'EOF'`).

**Fix:** always `git commit -F` from a file for anything longer than a line.

### 3.5 The host was not the host

The first designated host (`44.200.160.96`) turned out to be **the machine that
produced the 2026-07 performance reports** — same Xeon 8124M, same kernel, with
the old campaign directories still on disk. That was worth knowing: running
`lscpu -e` on it finally answered a question
`planning/verification-campaign-plan.md` had left open since July, and the
answer was the bad one.

It also failed qualification on disk (17 GiB against 100 needed), which is how
the second host appeared. **The second host is a different machine** — Xeon
8275CL, Ubuntu 26.04, kernel 7.0 — and under G1 that is a different environment.
The pre-registration was amended for it before anything ran.

## 4. Traps in this repository, for whoever comes next

- **`build/check.sh` takes ~30 minutes and must run as an unprivileged user.**
  `check_r1_resource_controls.sh` chmods a spool to 0500 and requires the
  preflight to see it non-writable; root ignores DAC.
- **Do not run anything heavy in parallel with the gate.** `tests/wp98-interop`
  timed out under contention while I was driving builds on the EC2 box from the
  same laptop. It passed 3/3 immediately afterwards, and passed on a clean
  `origin/main` worktree too. **Confirm against clean main before blaming your
  change** — the environment notes say this and they are right.
- **`git push` hangs**: the pre-push hook runs the whole gate. Run the gate
  yourself, then `--no-verify`.
- **`run-soak.sh` wants the candidate at `$BASE/repo`**, as a clean git
  checkout, and aborts with exit 4 otherwise. A `git clone --depth 1` preserves
  the real commit SHA and is ~20 MB.
- **`ops/soak/fixtures/` is generated** by `build.py`. Edit the generator, not
  the fixtures.
- **The pre-registration pins six instrument hashes** and
  `build/check_soak_controls.sh` fails on drift. That is intentional (G1) and it
  fired four times this session — every time correctly.

## 5. Findings that came from bookkeeping, not from looking for bugs

The two most interesting defects in WP06 were found while doing paperwork.

**Writing the BOM exposed two ledger defects.** The inventory counted 45 vendor
patch dispositions; the gate counted 44. Both were wrong:

- **ID 42 was used twice** — the T6/M7 deletion and the acceptor-saturation
  bridge. The source marker `DRUSE PATCH 42` points at the second, so the first
  **had no identity anyone could cite**;
- **`DELETED` was not a disposition the gate's pattern recognised**, so an entry
  resolved by removing 1,295 lines was invisible to the count — which is exactly
  how the duplicate survived: 45 rows reading as 44.

Neither would have been found by looking for bugs. They were found because two
independent counts disagreed and I chased the difference instead of picking one.

**The lesson generalises:** when two things that should agree do not, the
difference is the finding. Do not reconcile by choosing.

## 6. Where the instrument was the problem, not the product

Four of the five red runs in the WP04 ladder were the instrument. Worth stating
plainly, because the shape repeats:

| Red run | Cause | Actually a defect in |
|---|---|---|
| smoke 1 | `/stats` absent on 322 of 658 samples | the **runner**: it scraped `/stats` over HTTP on the same lanes it sampled, when ADR-050 had already moved the metric out of the request path and the runner had simply never passed the argument that turns the exporter on |
| smoke 2 | telemetry "stopped early", 658 of 681 | the **sampler**: `sleep 1` at the bottom of a loop whose body costs time makes the period `1 s + work`. Gaps measured 1.03–1.06 s with none above 1.5 s. It had never stopped |
| smoke 3 | two workloads over the error ratio | the **criterion**: `wait-40ms` failed on ONE error in 9,000, because a 0.01% ceiling cannot be expressed below 10,000 requests. And `eof_on_fresh_conn` is the acceptor's *documented* saturation refusal — the server was failing a criterion for keeping its own promise |
| burn-in 1 | RSS slope 2,328 KiB/h | the **criterion's window**: 720 samples is 12 minutes, and 12 minutes of a warming allocator cannot express a per-hour trend |
| burn-in 2 | health transport errors | **the product** — 8 errors on `/health`, 6 of them saturation refusals. This one is real and is capacity |

**The pattern worth carrying:** WP01 closed the instrument, WP03 closed the
observability, and **nobody closed the gap between them.** The out-of-band
metric channel that WP03 shipped had never once run in a campaign, because the
runner did not pass `argv[3]`. Two work packages can each be complete and leave
a hole between them that only running the thing finds.

## 7. Mistakes of judgement, and what caught them

For the record, since they are more instructive than the shell bugs.

1. **Assuming from present state instead of checking history.** The "3×
   contradiction" came from reading a flag as `true` today and concluding it was
   true for a measurement six hours older. **Caught by an adversarial audit**,
   not by me. One `git show` would have settled it.
2. **Answering the wrong question well.** The first runtime study evaluated the
   runtime as a speed instrument, because the conversation had opened on speed —
   and reached a correct conclusion for a question the owner was not asking. The
   right question was which *declared limitations* it removes. **Caught by the
   owner**, who had to say it twice.
3. **Returning decisions labelled as the owner's.** "Blocked on production
   traffic" was wrong: R2 §8's first canary step is shadow with synthetic load
   and needs no users. Calling it blocked was me not reading my own plan.
   **Caught by the owner**, and it was the fair complaint of the session.
4. **Using the wrong fixture and nearly publishing it.** The proxy-framing
   comparison ran against a server that does not serve `/ping` or `/echo`, so
   every handler case answered 404 on both legs. **Caught by me**, before
   publishing — and committed as INVALID rather than quietly re-run, because the
   next person needs to know what it suggested *and* why it cannot be cited.

**The one that generalises:** an adversarial reviewer found the error I could
not, and it was the load-bearing argument of the document. Commissioning
something to break your own work is worth more than another pass of writing it.

## 8. What is still owed, and by whom

- **Two 12-hour finals on different days.** Not a session limit — the
  repetition plan requires different days, and running them together produces
  an artefact the pre-registration itself refuses.
- **R2-WP07 canary steps beyond shadow.** Shadow runs on synthetic load; 1%/5%
  need a restricted service, or a formal accepted risk. The owner names the
  service or the waiver.
- **The ambition ADR.** R3 §1 requires it before implementation, and it is a
  statement about the product rather than an engineering choice.
