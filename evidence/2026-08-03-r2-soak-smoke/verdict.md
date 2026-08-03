# R2-WP04 smoke step — PASS, after three red runs that were all instrument

**Decision: the smoke step of the R2-WP04 ladder is GREEN. Nothing is promoted.
The gate stays at R1.**

`ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md` §5 is explicit that the
smoke step **cannot promote**: it exists to find wiring, schema, clock and hash
faults before twelve hours are committed to them. It did exactly that, four
times, and every fault it found was in the instrument or the criteria — not in
Druse.

## The ladder, run by run

| Run | Candidate | Verdict | Reasons |
|---|---|---|---|
| smoke 1 | `1c8ad3d` | FAIL | `/stats` absent on **322 of 658** samples; telemetry short; `bytes-64k` over ratio |
| smoke 2 | `1f9d9a1` | FAIL | `/stats` absent on **1 of 656**; telemetry short |
| smoke 3 | `b44f99b` | FAIL | `bytes-64k` and `wait-40ms` over ratio |
| **smoke 4** | `9905509` | **PASS** | — |

Each verdict is committed verbatim in `raw/smoke-N-verdict.json`.

## What each red run bought

### 1. The metric was travelling the path it measured

322 of 658 samples failed — 295 empty replies, 27 receive failures — because
`run-soak.sh` scraped `/stats` over HTTP once a second, on the same Handler lanes
it was sampling. At the pre-registered two lanes that is half the machine taken
from the measurement in order to take one.

**R2-WP03 had already decided against this channel.** ADR-050 moved the metric to
a snapshot written by a thread that owns no lane, and the soak server had already
grown the exporter. The runner had simply never passed `argv[3]` — so the channel
this project shipped in WP03 had **never once run in a campaign**. WP01 closed the
instrument, WP03 closed the observability, and nobody closed the gap between
them.

Fixed: the exporter is on, both the per-sample and per-cycle captures read the
file, and absence carries one cause from ADR-050's closed taxonomy — every one of
which names the application, which is why arm B was chosen over arm A.

### 2. The sampler was accused of dying, and it was keeping perfect time

658 samples of 681 expected, and the analyser called it *"telemetry stopped
early"*. The measured gaps were **1.03–1.06 s with not one above 1.5 s**. The
sampler had not stopped — `sleep $SAMPLE_SECONDS` at the bottom of a loop whose
body costs real time makes the true period `interval + work`, so it cost ~4%
more than the 2% tolerance allows. **Criterion 11 would have failed every run of
any length.**

R2-WP01 had recorded this exact revisit as an accepted risk (*"tolerance is 2%
and was chosen, not measured"*). The fix went into the sampler rather than the
tolerance: it sleeps the remainder of the interval, so the arithmetic becomes
true instead of the rule becoming lenient. Smoke 4 recorded **677 of 682**.

### 3. Two criteria were failing the server for keeping its own promises

```
bytes-64k  completed=90,000  errors=11  ratio=0.0122%  all eof_on_fresh_conn
wait-40ms  completed= 9,000  errors= 1  ratio=0.0111%  all eof_on_fresh_conn
```

`wait-40ms` failed on **one error in nine thousand**. Two defects, both in the
criterion:

- **Saturation refusals are a documented behaviour.** `docs/supported-profile.md`
  promises the acceptor "closes newly accepted sockets without writing an HTTP
  response and increments `saturation_refusals`" when every lane is busy. The
  generator sees that as `eof_on_fresh_conn`. Counting it as a spontaneous
  transport error made the server fail for doing what its profile says it does.
- **A ratio needs the volume to express it.** A 0.01% ceiling cannot be stated
  below `1/ceiling` = 10,000 requests. At 9,000 offered, the smallest non-zero
  rate the profile can produce is already over. That is not a tolerance.

Fixed, and the exemption is **checked rather than granted**: the analyser reads
`saturation_refusals` from the server's own final snapshot and refuses any run
where the generators saw more fresh-connection EOFs than the acceptor counted
refusals — otherwise the excuse becomes somewhere for real EOFs to hide. In
smoke 4: **168 seen by generators against 394 counted by the server**, one-sided
as expected for concurrent workloads.

## What the product did, across all four runs

Never the thing under suspicion. In smoke 3, the last run with full per-workload
figures:

| | |
|---|---|
| responses | **9,410,782** in ~11 min on two lanes over two physical cores |
| `completed` vs `planned` | **100% on all six workloads** |
| `server_exit` / `forced_kill` | 0 / 0 |
| `send_errors` | 0 |
| health p99 | under 250 ms in every cycle, zero transport errors |

The pre-registration's §3.4 predicted the offered rates would lose their basis
when lanes dropped from four to two. **They did not.** That is recorded here
because it was written down as an expectation beforehand and the measurement
contradicted it.

## What this does NOT establish

- **The smoke cannot promote and does not.** It is ten minutes. Burn-in,
  rehearsal and two twelve-hour finals are R2-WP04's actual content, and none of
  them has run.
- **No stability claim.** RSS slope, FD settling and thread constancy are
  criteria evaluated over hours; a five-cycle run says nothing about them.
- **No capacity claim.** The rates are offered load, not a ceiling. R2-WP05 owns
  the envelope and has not started.
- **The re-graded older artefacts are diagnostic only.** `raw/smoke-3-verdict.json`
  was produced by the *current* analyser against an artefact graded under the
  previous criteria. It is kept to show the ladder's history, and it is **not**
  evidence that smoke 3 passed — it did not, under the rules in force when it
  ran. Re-grading an old artefact under new criteria is exactly what G3 forbids
  as a promotion argument.
- **Criteria changed during the ladder, and that is recorded rather than
  hidden.** §3.6 of the pre-registration carries each amendment, the measurement
  that forced it, and why the smoke step's inability to promote is what makes it
  legitimate under G3.

## Next

Burn-in — 15 cycles, 30 minutes, where every workload and fault class must
appear at least once. Then the two-hour rehearsal, which is also where R2-WP01's
two remaining accepted risks are corrected: the 100 GiB disk estimate and the
evidence-volume figure.
