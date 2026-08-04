#!/usr/bin/env python3
"""Split a run's saturation refusals into injected and load-attributable.

    usage: attribute-refusals.py RUN_DIR [--json]

WHY THIS EXISTS. Criterion C23 of the R2-WP02 pre-registration requires every
step reporting `saturation_refusals > 0` to state how many fall inside a
declared injection window and how many do not. C22 then reads only the second
number: a rate descent responds to offered load, because lowering background
load does not remove 24 slow readers parked on two lanes.

The split was done by hand once, on the 2026-08-04 smoke, and by hand is exactly
how a criterion becomes optional. This script is the instrument catching up with
the criterion it was given.

WHERE THE WINDOW COMES FROM, AND WHY IT CAN BE TRUSTED. `control/injected.txt`
records only the START of each injection, at one-second resolution. The
durations live in `run-soak.sh`:

    slow_readers  24 sockets on /bytes/1m, then `time.sleep(8)`  -> 8 s
    rst           128 attempts at `-rst-delay 20ms`              -> ~2.6 s

Those are not guesses and they are not free parameters. `run-soak.sh` is pinned
by sha256 in §2.1 of the pre-registration, so a change to either duration
changes the instrument hash, fails `build/check_soak_controls.sh`, and creates a
new candidate. The durations are part of the candidate's identity.

THE WINDOW IS DELIBERATELY TIGHT. Attributing generously to injection would
shrink the load count, and a smaller load count makes C22 LESS likely to fire —
which is the direction that lets a campaign continue. So the bias is set the
other way: only refusals that clearly coincide with a declared injection are
credited to it, and everything else counts as load. Being wrong here should cost
a rate descent, not a false clean bill.
"""

import glob
import json
import os
import re
import sys

# Injection durations, from run-soak.sh. See the module docstring for why these
# are safe to hard-code and unsafe to guess.
INJECTION_SECONDS = {
    "slow_readers": 8.0,
    "rst": 128 * 0.020,
}
# The declaration is stamped with whole-second resolution and is written just
# BEFORE the injection starts, so the true start can be up to a second later
# than the stamp. Widen by one second each way, plus a two-second tail for
# sockets the server is still tearing down.
DECLARATION_SLACK_S = 1.0
TEARDOWN_SLACK_S = 2.0
UNKNOWN_KIND_SECONDS = 10.0  # a kind this script does not know: widen, do not skip


def parse_injections(run_dir):
    """Declared injection windows, as (start_unix, end_unix, cycle, kind)."""
    path = os.path.join(run_dir, "control", "injected.txt")
    if not os.path.exists(path):
        return [], None
    windows = []
    unknown_kinds = set()
    for line in open(path):
        fields = dict(
            part.split("=", 1) for part in line.split() if "=" in part
        )
        kind = fields.get("kind", "")
        utc = fields.get("utc", "")
        if not utc:
            continue
        # 2026-08-04T04:01:58Z
        import calendar, time as _t
        start = calendar.timegm(_t.strptime(utc, "%Y-%m-%dT%H:%M:%SZ"))
        if kind in INJECTION_SECONDS:
            duration = INJECTION_SECONDS[kind]
        else:
            duration = UNKNOWN_KIND_SECONDS
            unknown_kinds.add(kind)
        windows.append(
            (
                start - DECLARATION_SLACK_S,
                start + duration + DECLARATION_SLACK_S + TEARDOWN_SLACK_S,
                fields.get("cycle", "?"),
                kind,
            )
        )
    return windows, unknown_kinds


def refusal_steps(run_dir):
    """Every increase in saturation_refusals, as (unix_seconds, delta, total).

    The snapshot is a flat `key value` text file, not JSON, so it is read with a
    regex rather than a parser. A sample that cannot be read is REPORTED, never
    silently skipped — INS-013 in this repository: an absent measurement must not
    be rendered as a clean one.
    """
    samples = sorted(glob.glob(os.path.join(run_dir, "telemetry", "stats-*.json")))
    steps, unreadable, previous = [], 0, None
    for path in samples:
        try:
            text = open(path).read()
        except OSError:
            unreadable += 1
            continue
        refusals = re.search(r"^saturation_refusals (\d+)$", text, re.M)
        stamp = re.search(r"^unix_ns (\d+)$", text, re.M)
        if not refusals or not stamp:
            unreadable += 1
            continue
        total = int(refusals.group(1))
        when = int(stamp.group(1)) / 1e9
        if previous is None:
            previous = total
            if total:  # refusals already on the clock at the first sample
                steps.append((when, total, total))
            continue
        if total > previous:
            steps.append((when, total - previous, total))
        previous = total
    return steps, unreadable, len(samples)


def attribute(run_dir):
    windows, unknown_kinds = parse_injections(run_dir)
    steps, unreadable, sample_count = refusal_steps(run_dir)

    injected = load = 0
    detail = []
    for when, delta, total in steps:
        # ALL overlapping windows, not the first. Two injections are declared
        # in the same second on the fault cycle, and naming only one of them in
        # an evidence artefact points the next reader at the wrong mechanism:
        # 24 slow readers parked on two lanes and 128 RSTs are not the same
        # story about why the acceptor refused.
        hits = [w for w in windows if w[0] <= when <= w[1]]
        hit = hits[0] if hits else None
        if hit:
            injected += delta
        else:
            load += delta
        detail.append(
            {
                "unix_s": round(when, 3),
                "delta": delta,
                "running_total": total,
                "attributed_to": "injection" if hit else "load",
                "window": (
                    "; ".join(f"cycle={w[2]} kind={w[3]}" for w in hits)
                    if hits
                    else None
                ),
            }
        )

    return {
        "run_directory": run_dir,
        "telemetry_samples": sample_count,
        "unreadable_samples": unreadable,
        "declared_injections": len(windows),
        "unknown_injection_kinds": sorted(unknown_kinds or []),
        "saturation_refusals_total": injected + load,
        "refusals_inside_injection_window": injected,
        "refusals_attributable_to_load": load,
        "c22_descent_required": load > 0,
        "steps": detail,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    result = attribute(args[0])

    if "--json" in sys.argv[1:]:
        print(json.dumps(result, indent=2))
        return 0

    print(f"run:                    {result['run_directory']}")
    print(f"telemetry samples:      {result['telemetry_samples']}"
          f" ({result['unreadable_samples']} unreadable)")
    print(f"declared injections:    {result['declared_injections']}")
    if result["unknown_injection_kinds"]:
        print(f"  UNKNOWN KINDS:        {result['unknown_injection_kinds']}"
              f" — widened to {UNKNOWN_KIND_SECONDS}s each, and this line is the warning")
    print()
    print(f"saturation_refusals:    {result['saturation_refusals_total']}")
    print(f"  inside an injection:  {result['refusals_inside_injection_window']}")
    print(f"  attributable to load: {result['refusals_attributable_to_load']}   <-- C22 reads THIS")
    print()
    if result["c22_descent_required"]:
        print("C22: DESCENT REQUIRED — offered load produced refusals at this rate.")
    else:
        print("C22: no descent — offered load produced no refusals at this rate.")
    if result["steps"]:
        print()
        print("steps:")
        for s in result["steps"]:
            where = s["window"] or "no declared injection active"
            print(f"  +{s['delta']:<5d} -> {s['running_total']:<6d}"
                  f" {s['attributed_to']:<10s} ({where})")
    # The analyser's own habit: always print a verdict, always exit 0. The
    # verdict is the output, not the exit status.
    return 0


if __name__ == "__main__":
    sys.exit(main())
