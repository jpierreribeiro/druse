# Diagnosability — the standard an instrument must meet

**Status: NORMATIVE, 2026-07-30.** This document applies to every instrument in
this repository that produces a verdict, a published number, or release
evidence. It is enforced the way everything else here is enforced: by a control
in the gate that fails when the property is absent.

## The property, and why it is not the one we already had

This project has been bitten eight times by tests that did not work, and every
one of them is in the history:

| Commit | What it was |
|---|---|
| `e7ae6b5` | a second suite that could not fail; audit all 43 and gate the pattern |
| `0b1fea8` | the wire corpus could never fail |
| `f06c447` | the drain "flake" was the c03 race; six suites nobody ran |
| `77bf2a1` | one case passed for the wrong reason |
| `28c977e` | one fix was guarded by an unrun suite |
| `086eb9e` | wp90-deadlines was never a flake |
| `a439618` | two falsified records |
| `2bcc62c` | a green job asserted the build fails; it failed on a flag of ours |

The answer this project invented is the **mutation control**: break the code on
purpose, require the test to go red. Forty-one of them run in the gate. That
discipline is mature and it answers one question:

> **Falsifiability** — can this test fail?

It does not answer the other one:

> **Diagnosability** — when it fails, will the artefact say exactly why?

Nothing in the gate required an answer to the second, so nothing provided one.
On 2026-07-29 a 12-hour soak recorded **674 transport failures across 390
million calls**, satisfied every criterion, and could not name a single cause.
The generator stored a boolean and dropped the error value; the server under
test installed neither a logger nor an observer, so every framework diagnostic
was discarded twice over; the per-request log the generator could already write
was never requested; and nothing carried an absolute timestamp, so the records
that did exist could not be joined to each other.

Nobody was careless. The standard was missing.

There is a third question, and it went unasked longer than either of the others
because a green result does not prompt anyone to ask anything:

> **Attribution** — when it *passes*, is it passing for the reason it names?

Rule 4 below is that question, with the episode that forced it.

## The four rules

### 1. No discard

An instrument that observes a failure **records its cause**, not a counter.

If the code has an error value in hand, that value reaches the artefact. A
boolean, a tally, or a status of `0` standing in for six different causes is a
violation. Where the set of causes is known, classify into a **closed taxonomy**
and keep the verbatim text as well — a taxonomy without the raw text cannot be
audited, and raw text without a taxonomy cannot be counted.

A cause outside the taxonomy is reported as `unclassified`. It is never folded
into a neighbouring class, because a new failure mode that disguises itself as
an old one is worse than one that is merely unnamed.

### 2. Correlatable

Every record carries **absolute time** — unix nanoseconds, not an offset from a
start the artefact never printed — and enough identity to be joined to the other
records of the same run.

The test: can an analyst take one failure and ask what the server, the kernel and
the other workloads were doing in that instant? If the answer requires a
timestamp nobody wrote down, the instrument fails this rule.

### 3. No anonymous tolerance

**No criterion may accept a rate of anomaly without requiring each anomaly to be
attributed.**

This is the rule that would have caught the 674. A ceiling of "at most 0.01%
transport error" is satisfied by 674 unexplained failures exactly as well as by
zero. The ceiling is not wrong and it stays; what it cannot express is added
beside it:

> Every failure carries a named cause. A failure that is unclassified, or
> counted with no class at all, fails the run **regardless of the rate**.

This is strictly stronger, and it is affordable precisely because a healthy run
produces few failures. If an instrument cannot afford it, that is evidence about
the instrument, not an argument against the rule.

**The rule applies to countable anomalies, not to continuous measurements.**
This distinction is load-bearing, and it was sharpened by auditing against a
criterion that turned out to be sound. A failure, a refused request, a dropped
connection is a discrete event with a cause that can be named, and each one must
be. RSS, latency and throughput are continuous, and a threshold is the only way
to judge them — `tests/c04-response-size` allows 2 MiB of growth and says why
("allocator bookkeeping and test-side buffers"), which is a stated derivation,
not an anonymous allowance. Demanding an "attribution" for every byte of RSS
would be the rule applied past its meaning.

So a threshold on a continuous measurement is legitimate, and carries its own
obligation: **say where the number came from.** `build/check_wp26_bench.sh`
derives its tolerance floor from the machine, and `build/check_phase4_freeze.sh`
refuses a freeze that makes a performance claim from inside the instrument's own
noise — "a percentile from inside it is a number about the machine". That is the
standard for thresholds, and it already exists here.

A criterion of the form "at most X% of *events*" is the shape that hides cause by
construction. Every one of them in this repository is suspect until it has been
read against this rule.

### 4. No unattributed pass

**An assertion that an outcome is expected must match the CAUSE of that outcome,
not only its exit status.**

Rules 1 to 3 all concern an instrument that goes red. This one concerns an
instrument that goes **green**, which is harder, because green is the state
nobody investigates.

> A green result proves **the assertion you wrote was satisfied**. It does not
> prove **the thing you wanted to prove**. Those two coincide only when the
> assertion names the cause.

The episode. `.github/workflows/gate.yml` runs a portability job whose expected
outcome is a **compile failure**: Druse is Linux by construction, because the
vendored transport binds `core:sys/linux`, and the job is the executable proof
of the README's platform claim. It asserted that the build fails. It was green.
It was green on Windows because `-out:hello` is missing an extension there, so
the Odin driver rejected the output path **before compiling a single line of
Druse**. A workflow bug of ours was being reported as a portability limit, and
the exit status could not tell the two apart because a failure is a failure.

What makes this rule distinct from falsifiability: a mutation control would not
have caught it. Break the transport and the job stays green — it was already
green for a reason unrelated to the transport. The assertion was falsifiable and
diagnosable and still wrong, because it never named what it was asserting about.

The fix, and the shape to copy (`gate.yml`): after observing the expected
failure, `grep` the diagnostic for the tokens the documented cause would
produce — here `is not declared by 'linux'`, `core:sys/linux`, `sched_yield`,
`setsockopt_base` — and **fail loudly when they are absent**, with a message
that says the run would otherwise have reported a workflow bug as a portability
limit. The full diagnostic is printed either way, so a human can see what
actually happened.

This rule is where the repository's existing practice was already correct and
merely unwritten: roughly twenty controls under `build/` match an expected
diagnostic rather than an exit status, and `gate.yml` cites that body of
practice as its own justification. Rule 4 makes it the standard instead of a
habit.

**Corollary — an advisory assertion is not an assertion.** A check that cannot
fail the run it belongs to has been downgraded to a log line. Where infrastructure
noise is the reason for tolerating failure, isolate the noisy step and let the
assertion itself block.

## How it is enforced

Each instrument that falls under this standard carries a control in the gate
that proves the property, in the shape `build/check_*_controls.sh` already uses:

- a **positive** case: a deliberately caused failure must arrive classified,
  with its text, locatable in absolute time;
- one or more **mutations** of the instrument that remove the diagnostic and
  must be detected;
- where an analyser computes the verdict, a case proving it **refuses** an
  artefact whose failures carry no cause;
- for rule 4, a case proving the instrument **refuses a pass obtained for the
  wrong cause** — feed it an expected-shaped outcome whose diagnostic does not
  match, and require it to go red. An expected-failure assertion with no such
  case is unexamined.

The positive case is not decoration. Without it, a typo in an assertion lets
every mutation "pass" against any artefact at all — which is exactly how
`0b1fea8` happened.

`build/check_soak_controls.sh` is the reference implementation, and
`ops/soak/CRITERIA.md` is the reference for criteria that carry their own
history.

## Instruments in scope

Anything that produces a verdict, a published number, or release evidence:

- the soak (`ops/soak/`) — **done**, and the model for the rest;
- the JSON/HWM measurement harness;
- the benchmark matrices under `bench/`;
- every gate script whose criterion is a tolerance rather than a fact;
- **every assertion whose expected outcome is a failure** — rule 4's scope, and
  the one that reaches outside `build/` into `.github/workflows/gate.yml`. The
  shipped operational artefacts belong here too: `ops/deploy/druse.service` was
  read by nothing for months while ten documents drifted away from its
  `Restart=` value, which is the same defect one layer out — an artefact whose
  correctness no instrument ever asserted.

The audit of the remaining instruments against these four rules is tracked
separately. An instrument that has not been audited is not thereby compliant; it
is unexamined, and the difference matters.

## Criteria live in version control

The soak criteria were relaxed after a red result — the offered load was about
halved and the transport-error rule went from zero errors to at most 0.01%.
Proving that required running the current analyser over the old data and
comparing message strings, because the harness lived outside git.

The relaxation was defensible. The invisibility was not. **A criterion with no
history is a criterion that can be moved to fit a result, and nobody will be
able to tell afterwards.**
