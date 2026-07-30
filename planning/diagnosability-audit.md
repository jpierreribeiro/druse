# Diagnosability audit — first pass

Instruments read against the three rules in
[`diagnosability.md`](diagnosability.md). Started 2026-07-30, after a 12-hour
soak counted 674 transport failures and could not name one of them.

**The headline, stated up front because it is the opposite of what I expected to
find: the blindness was in the harness, not in the framework.** Every framework
counter examined so far is documented at the point of declaration, and every
threshold examined states where its number came from. The one instrument that
violated all three rules is the one that produced the release evidence.

## Rule 1 — no discard

| Instrument | Verdict | Evidence |
|---|---|---|
| soak generator (`openload`) | **VIOLATED — fixed** | stored `err: true` and dropped the error value; 1,283 `.err` files at 0 bytes. Now a closed taxonomy plus verbatim text |
| soak server under test | **VIOLATED — fixed** | installed neither a logger nor an observer, so every framework diagnostic was discarded twice over; `server.log` was 0 bytes in every run |
| soak orchestrator | **VIOLATED — fixed** | never passed `-raw`, so the per-request log the generator could already write was never produced |
| framework stream counters | sound | `stream_refused_full` groups the per-stream event and byte caps, and the field comment says so — *"a per-stream event/byte cap refused a send"* — distinct from `stream_refused_budget`, the process-wide budget. A deliberate axis, declared |
| framework `Server_Stats` | sound | ten integers, each with a one-line meaning at the declaration; `saturation_refusals` even carries the reason it is not a 503 |

## Rule 2 — correlatable

| Instrument | Verdict | Evidence |
|---|---|---|
| soak, whole run | **VIOLATED — fixed** | nothing carried absolute time. Latencies were relative to a `scheduleStart` the artefact never printed, so no client failure could be placed inside any server sample |
| soak telemetry | **partially fixed** | `/stats` was sampled every 5 s while the refusal bursts it needed to catch have a median of one event. Now 1 s, with unix nanoseconds and kernel counters |

## Rule 3 — no anonymous tolerance

| Criterion | Verdict | Evidence |
|---|---|---|
| soak: "at most 0.01% transport error" | **VIOLATED — fixed** | satisfied by 674 unexplained failures as well as by zero. Ceiling kept; accounting added beside it |
| `tests/c04-response-size`: 2 MiB RSS growth | sound | continuous measurement, and the derivation is stated — allocator bookkeeping and test-side buffers. This is what sharpened the rule to be about countable anomalies rather than measurements |
| `build/check_wp26_bench.sh` | sound | derives its tolerance floor from the machine rather than asserting one |
| `build/check_phase4_freeze.sh` | **exemplary** | refuses a freeze that makes a performance claim from inside the instrument's own noise floor — *"a percentile from inside it is a number about the machine"* |

A mechanical sweep of `build/*.sh` and `build/*.py` for tolerance-shaped
criteria returned no anonymous allowance. The matches were about *deriving* and
*stating* tolerances, which is the obligation, not the violation.

## Coverage — an instrument nobody runs proves nothing

Not one of the three rules, but found while auditing and the same family of
defect. Of 109 test directories, six were referenced nowhere in `build/` or
`.githooks/`:

| Directory | Disposition |
|---|---|
| `g76-scale-sockets`, `nbio-timeout` | referenced from `ops/`; the VPS campaign's, deliberately outside this gate |
| `head-content-length`, `ingest-leak` | **regression tests for two of the seven subsystem-audit fixes**, referenced only by the gates of experiment worktrees kept outside version control |
| `wp118-accept-multishot`, `wp7_5-c1-inbound-stream` | same, referenced only from outside worktrees |

All four pass when executed, so this closed a coverage hole rather than a
regression. They are in the gate now. This is the `28c977e` pattern — "one fix
was guarded by an unrun suite" — under different names.

`check_wp67_controls.sh` looked orphaned and is not: a deliberate shim that
`exec`s the WP68 controls, which the gate runs. Checked before reporting, which
is the standard this document holds itself to.

## Not yet audited

The 110 test suites individually, the JSON/HWM measurement harness
(`analyze-json-hwm.py`), and the benchmark matrices. An instrument absent from
this document is **unexamined, not compliant**, and the difference is the whole
point of writing the list down.
