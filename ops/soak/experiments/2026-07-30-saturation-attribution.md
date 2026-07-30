# Pre-registration — what are the soak's transport failures?

**Written before the experiment runs. That is the point of the file.**

## The question

A 12-hour soak on 2026-07-29 (`9b46a46`) recorded **674 client-side transport
failures across 390 million calls**, and its instrument could not name one of
them. This experiment decides whether those failures are the framework's own
saturation shedding seen from the client, or something else.

## What is already established, from the run's own data

| Evidence | Value |
|---|---|
| Correlation, per 2-minute cycle, between client failures and Δ`saturation_refusals` | **+0.850** |
| Cycles with a client failure and **no** saturation refusal | **0 of 212** |
| Cycles with a refusal and no client failure | 34 |
| Totals | 674 failures against 1,254 refusals |
| Correlation with `send_errors` | +0.120, and 48 per fifth cycle — that is the deliberate RST injection |
| Every failure's HTTP status | `0` — no response was ever received; none was a body-read failure |

At 5-second resolution the refusals look different from "the server is at
capacity": only **406 of 5,621** intervals contain any refusal at all, the median
affected interval contains **one**, and the correlation between refusals and the
response volume in the same interval is **+0.009** — essentially none. So the
refusals are brief, isolated events scattered through the run, not a function of
offered load.

The client failures cannot be joined to those 5-second windows, because the old
generator recorded no absolute time. That is the gap this experiment closes.

## Hypothesis

**H1.** The transport failures are `saturation_refusals`: the framework refuses
before HTTP dispatch, so the refusal reaches the client as a connection closed
with no response, which the client can only record as a transport failure.

## Predictions, registered in advance

Three arms, each ~15 minutes, run in alternating order, on the same host, with
the instrument from `ops/soak/`.

| Arm | Change | Prediction if H1 holds | Prediction if H1 is false |
|---|---|---|---|
| **A — control** | identical to the soak: 4 lanes, all six profiles | failures at roughly 1.7 per million, and `saturation_refusals` moving with them | same failures, refusals near zero |
| **B — more lanes** | `DRUSE_SOAK_LANES=16` | failures **and** refusals both fall to ≈0 | failures persist while refusals fall |
| **C — no blocking handler** | `DRUSE_SOAK_WAIT_40MS_RATE=0` | failures **and** refusals both fall to ≈0 | failures persist while refusals fall |

**H1 survives only if failures and refusals fall together in both B and C.**
A fall in refusals with failures persisting refutes it, and in that case the
per-request CSV already carries the real cause, because the new generator writes
the error class and text for every failure.

## What the new instrument adds that makes this decidable

- every failure carries a class from a closed taxonomy plus its verbatim text;
- every request carries absolute scheduled/sent/done nanoseconds, so a failure
  can be placed inside a 1-second `/stats` window;
- `/stats` is sampled every second rather than every five;
- kernel counters (`ListenOverflows`, `ListenDrops`, `TCPAbortOnClose`,
  retransmissions) are recorded, which separates "the kernel dropped it before
  the server saw it" from "the server refused it";
- connection reuse and extra dials are counted, so Go's silent retries stop
  hiding failures that succeeded on a second attempt.

## Falsification conditions, stated in advance

The experiment fails to settle the question — and says so rather than reaching —
if any of these hold:

1. arm A produces **no** failures at all (nothing to attribute; the effect did
   not reproduce at this duration);
2. failures arrive `unclassified` (the taxonomy is wrong, and the run is red by
   `planning/diagnosability.md` rule 3);
3. `ListenOverflows` or `ListenDrops` move during the failures (the kernel is
   involved, and neither H1 nor its stated alternative describes that).

## Decision this feeds

The `v0.10.0` tag is waiting on it. A confirmed H1 means the failures are a
documented, deliberate behaviour observed from the wrong side, which is a
product-observability finding (`docs/operations.md`, and the 503 prototype),
not a defect in the release. A refuted H1 means an unexplained failure at 1.7
per million remains, and the tag waits for what the CSV then shows.
