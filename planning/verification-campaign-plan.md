# Verification campaign: what the merged fixes still owe

Status: **PLAN / NON-IMPLEMENTING.** This authorizes verification work and the
test harnesses that produce it. It authorizes no public API and no framework
behaviour change, with one named exception (Campaign C, which needs an owner
decision first).

## Why this exists

Commit `44bdcda` merged nine defect fixes. Five carry a negative control — the
fix was reverted and the test observed going red. **Four do not**: the
acceptor/lane memory-ordering fix, the shutdown teardown gate, the dead-lane
shutdown, and the `timespec` split. Those four are the newest code in the
concurrency path and they rest on argument alone.

Worse, the suite that exercises exactly that code — `tests/c03-fault-campaign` —
**could not be completed anywhere during the audit**, on the patched tree or on
pristine `61bec774`. So the RST-flood verdict the project relies on is currently
unverified against the code that now ships.

This plan closes that, and the two suites that are red on `main`.

## The box you have will not do this, and here is the arithmetic

From `ops/verification/2026-07-24-hardening-vps.md`, the current verification
VPS is 2 CPUs, 1636 MiB total with ~830–890 MiB available, `ulimit -n` 1024,
`ulimit -l` 8192 KiB, shared with Caddy (80/443/2019), a docker `runner`, a
service on 8090, and the `uruquim-ci` timer.

Every campaign below is blocked by one of those numbers:

| Constraint | Value | Why it blocks |
|---|---|---|
| CPUs | 2 | The framework's own default is four Handler lanes, and the load generator needs cores that are not the server's. At 2 CPUs the client and server contend, so a stall looks like slowness and slowness looks like a stall — the exact confusion these campaigns must not have. |
| `ulimit -n` | 1024 | C-03 opens tens of thousands of sockets per second. 1024 descriptors is not a tuning inconvenience; the flood cannot be generated at all. |
| `ulimit -l` | 8 MiB | Each lane's io_uring rings pin memory against `RLIMIT_MEMLOCK`. This is the documented cause of F-C03-2, and ASan builds (Campaign B needs one) make it worse. |
| RAM | ~850 MiB free | A 12–24 h soak measuring RSS plateau cannot share a box with services that have their own memory behaviour. |
| Tenancy | shared | Caddy and a docker runner produce scheduling noise that a latency plateau cannot be distinguished from. |

**Do not reconfigure the current VPS to fit.** It runs the CI timer that
verifies `main`; making it also the stress box couples "is main green" to "did
the flood harness just exhaust the fd table". Keep the CI box as it is.

## The box: the existing c5.2xlarge, with three corrections

The c5.2xlarge already used for the benchmark work is the right shape for
Campaigns A–D — 8 vCPU, 16 GB, dedicated (not burstable), local NVMe, and a
kernel with io_uring unrestricted. Nothing new needs to be bought. Three things
about it must be corrected before it produces trustworthy results.

### 1. It has four physical cores, not eight

A c5.2xlarge is 4 physical cores × 2 hyperthreads. The existing benchmark
pinning — server on CPUs 0–3, `wrk` on 4–7 — is almost certainly pinning them
onto *sibling threads of the same physical cores*, so "client and server cores
are disjoint" is true only at the logical level. Confirm before anything else:

```bash
lscpu -e   # read the CORE column: siblings share a core id
```

On the usual Nitro layout the pairs are (0,4) (1,5) (2,6) (3,7), which makes the
disjoint split `0,1,4,5` for one side and `2,3,6,7` for the other — two physical
cores each. Record the actual topology; do not assume this one.

**This changes the harness designs**, and mostly for the better:

- **Campaigns A and B: use 2 Handler lanes, not 4.** Fewer lanes leaves real
  cores for the load generator and the canary, and a stall detector that has to
  compete with the server for CPU produces false positives — which is the one
  failure mode these campaigns cannot afford. Two lanes also makes saturation
  *easier* to reach: the handoff cap is `2 × lanes`, so four in-flight
  connections fill it, instead of eight.
- **Campaign D (soak): generate load from a second, small instance** in the same
  AZ and subnet, over the private IP. A c5.large or t3.medium is enough for the
  rates involved. This costs little, frees all four physical cores for the
  server, and removes loopback from the measurement — so it also delivers part
  of Campaign E's two-box requirement as a side effect.

### 2. Its limits are almost certainly the stock AMI defaults

The current CI VPS failed on exactly these, and a fresh EC2 AMI ships the same
shape: `ulimit -n` 1024 and a small `RLIMIT_MEMLOCK`. Set them per the host
preparation block below, and set them **persistently** (`/etc/security/limits.conf`
plus `LimitNOFILE`/`LimitMEMLOCK` in any systemd unit), because a 24 h soak
started from a login shell that inherited the default is a soak that fails at
hour three for a reason nobody will connect to descriptors.

### 3. It must not be running anything else

If this is the same instance that hosts other work, stop that work for the
duration or use a fresh instance from the same AMI. Campaigns B and D are
sensitive to scheduling noise in ways a throughput benchmark is not.

**A second box is needed for Campaign D's load generator (above) and for
Campaign E** (the benchmark claim), on the same VPC/subnet so the NIC path is
real. E is optional and lowest priority; correctness comes first.

### Host preparation, exactly

Record the output of every one of these in the campaign log — a run whose host
state is unknown is a run that cannot be compared to the next one.

Set these for the session AND persistently (`/etc/security/limits.conf`, and
`LimitNOFILE=`/`LimitMEMLOCK=` on any systemd unit that runs a campaign). A
24 h soak that inherited the AMI default fails at hour three for a reason nobody
traces back to descriptors.

```bash
# Descriptors: C-03's flood needs tens of thousands live at once.
# The EC2 AMI default is 1024.
ulimit -n 1048576

# Memlock: io_uring rings pin against this. The 8 MiB default is what
# produced F-C03-2. Unlimited removes the variable entirely.
ulimit -l unlimited

# Ephemeral ports and TIME_WAIT recycling, or the flood exhausts the
# port range long before it stresses the acceptor.
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_fin_timeout=15

# Backlog: the acceptor's own listen backlog is 1000; do not let the kernel
# drop SYNs before the framework's admission logic is reached.
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535

# Conntrack: if any firewall/NAT module is loaded, a flood fills the table
# and the failure looks like the server refusing connections.
sysctl -w net.netfilter.nf_conntrack_max=1048576   # only if nf_conntrack is loaded
lsmod | grep -c nf_conntrack                        # record whether it is
```

Then: `lscpu -e`, `uname -a`, `free -m`, `ulimit -a`, and the pinned toolchain
check (`ops/ci/install-odin.sh` verifies the SHA and commit).

## Rules for the agent running this

These are not style preferences. Every one of them exists because the audit
found the corresponding failure in work already merged.

1. **A harness proves nothing until it has caught the bug.** Before any green
   result is recorded, revert the fix under test and observe the harness go
   red. If it stays green with the fix reverted, the harness does not measure
   what it claims and its green result must not be reported as evidence.
2. **If the negative control cannot be made to fail, say so in those words.**
   Some of these are narrow races that may not reproduce on any given hardware.
   "The harness ran 10 h clean but could not reproduce the defect on reverted
   code, so it bounds nothing" is a legitimate and useful outcome. Silence, or
   reporting the green run alone, is not.
3. **Commit raw artifacts, never only prose.** Every number that reaches a
   report must be regenerable from a committed script, and the run's raw output
   must be committed beside it. The audit found the README's headline benchmark
   table has no committed peers and no committed `wrk` invocation anywhere in
   the tree; do not add a second instance of that.
4. **Record host state with every run** (the block above). A latency or memory
   number without `lscpu -e`, limits and kernel version is not comparable to
   anything.
5. **Report thresholds as configured, not as observed.** The C-03 gate's
   committed bar is "≥ 50% of healthy probes served during the flood"; a run
   that served 58/58 is an observation, not the bar. Write both.
6. **One variable per run.** Campaigns A and B both touch the accept path; do
   not run them concurrently on the same box.

---

## Campaign A — C-03 completes, and the RST-flood verdict is re-established

**Blocking. Nothing else here matters if the accept path is not verified.**

The suite did not finish in 35+ minutes during the audit, on patched and
pristine trees alike. The first question is not "does it pass" but "why did it
not finish".

**A1. Diagnose the non-completion.** Run `tests/c03-fault-campaign` with the
host prepared as above. If it still does not finish, attach to the running
process and find where it is: `gdb -p` for the stack, `ss -s` for socket-state
exhaustion, `dmesg` for conntrack/backlog drops, `strace -c -p` for a syscall
that is spinning. Distinguish three outcomes and say which one it is:
- resource exhaustion on the old host (expected — record the limit that bound);
- a genuine hang in the framework (**stop everything and report**; that is a
  finding above every other item in this plan);
- a slow-but-progressing test (record the wall time; consider whether the
  fixture is larger than it needs to be).

**A2. Run to completion, three consecutive times.** Record for each: healthy
probes served during flood, probes recovered after, wall time, and the
configured threshold beside the observed value.

**A3. Negative control.** Revert `URUQUIM_ACCEPT_HANDOFF_LIMIT` from 2 to 8 and
confirm the suite fails. This control is already the documented basis for the
constant; re-establishing it on this hardware is what makes the passing runs
mean anything here.

**Acceptance:** three consecutive completed runs, all above the committed
threshold, plus a failing run at limit 8. **Artifact:**
`docs/reports/<date>-c03-reverification.md` with raw output committed.

---

## Campaign B — the four uncontrolled transport fixes

Each sub-campaign must first reproduce the defect on reverted code.

**B1. Lost wakeup (acceptor parks with an unplaceable connection).**

Harness shape: a server with **2 lanes** (see the topology note — two physical
cores for the server, two for the generator and canary) and a handler that
dwells long enough to keep both lanes busy; a wave generator that opens
`2 × lanes + margin` connections in lockstep so every lane reaches its handoff
cap simultaneously; then **traffic stops completely** for 3–5 s. A separate
canary client then connects and issues one request with a 2 s timeout.

The failure signal is precise: the canary times out *while the server has no
in-flight work*. That is the stall — not slowness, since there is nothing to be
slow about.

- **Negative control first:** revert the seq-cst store + re-scan in
  `accept_try_assign_pending` (and the seq-cst loads in `accept_choose_lane`,
  `on_connection_assigned`, `handler_lane_leave`) and also remove the bounded
  `ACCEPT_STALL_RECHECK` tick, since that tick would mask the stall. Run until a
  canary failure is observed. Record how long it took.
- **Then the fix:** run at least 10× that duration, or 6 h, whichever is longer,
  with zero canary failures.
- If the control never fails: report that the race could not be reproduced on
  this hardware, and that the fix therefore stands on the memory-model argument
  alone. Do not report the clean run as proof.

**B2. Shutdown use-after-destroy.**

Harness shape: a loop that starts a 2-lane server, fires a connection from
another thread, calls `web.stop()` with a delay swept across the microsecond
range between "connect issued" and "stop called", joins, and repeats. Fewer
lanes is again the right choice: an idle lane completes its shutdown fastest,
which is precisely the timing that opens the window. Build with
`-sanitize:address`. The memlock limit above is required or ASan plus io_uring
reproduces F-C03-2 instead of the bug under test.

- **Negative control:** remove the `accept_drained` gate in
  `_server_thread_shutdown` and the `closing` check at the top of
  `on_accept_dedicated`; expect an ASan report (use-after-free / use-after-poison
  in the lane's operation pool or MPSC buffer) or a crash.
- **Then the fix:** ≥ 50,000 iterations across the delay sweep, zero ASan
  reports.

**B3. Dead lane stays selectable.**

Fault-inject a tick error on one lane (simplest: a build-time hook that returns
`.EBUSY` from `_flush_submissions` once, on one lane, after N ticks). Before the
fix the server keeps serving at reduced capacity with two connections stranded;
after it, the server shuts down. Assert the post-fix behaviour: the process
exits rather than silently losing a lane.

**B4. `timespec` split — ALREADY DONE, AND THE CONTROL FALSIFIED THE CLAIM.**

`tests/nbio-timeout` is committed and green. Its control was run: with
`ts.time_nsec = uint(timeout)` restored, all three cases still pass on Linux
6.18.5, because the kernel normalises an over-large `tv_nsec` on the io_uring
EXT_ARG path rather than rejecting it with EINVAL as the audit predicted.

So the split is a conformance repair, not a fix for an observed failure, and the
test is a regression guard rather than controlled evidence. Both the report and
the test header now say so. **No stress-box work is owed for B4.**

The agent should still re-run it on the campaign host: a different kernel or a
different io_uring feature level may not normalise, and if the control fails
*there*, that is worth recording — it would mean the defect was real on some
kernels, which changes nothing about the fix but does change what the project
knows.

**Acceptance:** for each of B1–B3, either (control failed → fix ran clean) or an
explicit "could not reproduce" statement. B4 green as a committed test.
**Artifact:** the harnesses under `tests/` or `experiments/`, plus
`docs/reports/<date>-transport-race-campaign.md`.

---

## Campaign C — `lane_collisions` and a green `c05`

**This one needs an owner decision before any code is written.**

`tests/c05-saturation` is red on `main`: *"the ramp produced no lane 503 at
all"*, with `lane_collisions=0`. That is not a broken test. Under dedicated
accept, handlers run synchronously on the lane thread, so the event loop is
blocked during dispatch and `handler_lane_enter` can essentially never return
false. The 503-on-collision path and the counter that observes it are
unreachable. The real behaviour — a keep-alive request arriving at a lane stuck
in a slow handler — is silent head-of-line queueing: no 503, no metric, only
latency.

The framework's first saturation point is currently invisible, and production
guidance names this metric as the thing to watch.

Three options, for the owner:

1. **Redefine the metric as queueing delay.** Measure the interval between "the
   request's bytes were readable" and "dispatch began", per lane, as a
   histogram. This observes what actually happens now. Costs a timestamp per
   request on the hot path.
2. **Keep the counter, change what trips it.** Count requests whose dispatch
   waited longer than a configured threshold. Cheaper, coarser, still visible in
   `web.stats()`.
3. **Retire it.** Remove `lane_collisions` from `Server_Stats`, delete the
   unreachable 503 path, and change the operations documentation to say the
   saturation signal is p99 latency. Honest, and it is a public-surface removal
   that needs its own freeze-ledger treatment.

Whichever is chosen, `c05` then asserts the new contract and must pass.

**Do not skip to option 3 because it is cheapest.** The audit's judgement is
that a framework whose primary saturation mode is invisible is harder to operate
than one whose metric is imperfect — but that is the owner's call, not the
agent's.

---

## Campaign D — the long soak

Only after A and B are green, and on a box running nothing else.

**Workload:** 12–24 h, mixing in one run — keep-alive traffic at steady rate,
connection churn (`Connection: close` at a fraction of requests), periodic RST
bursts, slow-header and slow-body clients, slow-reading clients, and **mixed
response sizes** (this is the one that matters for memory: per-connection
buffers retain roughly the largest response that connection ever served, and
with `max_idle_time = 0` idle connections are never reaped, so a uniform-size
soak cannot see the ratchet).

**Record every 30 s:** RSS, open fds, `web.stats()` counters in full, requests
completed, 503 count, and a latency quantile for the interval.

**Acceptance:**
- RSS reaches a plateau and stays within a stated band after hour 2 — state the
  band as a number before the run, not after;
- zero crashes, zero unexplained connection resets;
- 503 rate below a stated threshold;
- fd count returns to baseline after each churn phase (a monotonic climb is a
  descriptor leak and is a finding).

**Artifact:** the time series committed as CSV, plus
`docs/reports/<date>-soak-<hours>h.md`.

---

## Campaign E — the benchmark claim (optional, lowest priority)

Only if the public performance table matters commercially right now. It is
listed last deliberately: none of it affects whether the framework is correct.

1. Commit the missing peers — fasthttp, Axum, `net/http`, Gin, Fastify `/ping`
   servers with lockfiles, under `bench/framework_ping/peers/`.
2. Commit an orchestrator that starts each with its exact configuration
   (`taskset` pinning, `GOMAXPROCS=4`, Fastify `WORKERS=4` — the committed
   default is 1, which contradicts the reported config), runs warmup plus N
   timed repetitions, and writes raw `wrk` output into the repository.
3. Equal run counts for every framework — the current table compares a
   three-run peer median against a five-run Uruquim median.
4. Report dispersion, not just medians, and state the rig's measured noise
   floor. The "faster than Axum" claim rests on 3.6% with no error bars.
5. For any p99 claim, add a fixed-rate open-loop measurement (wrk2 or vegeta) at
   matched offered load. Closed-loop `wrk --latency` compares each server's own
   queueing, not its service time; `--latency` prints a histogram, it does not
   correct coordinated omission.
6. Two boxes over a real NIC, replacing loopback.

Until 1–2 exist, the README table stays labelled as it now is: a recorded
observation on one box, not a reproducible result.

---

## Order, and what each unlocks

```
A (c03 completes + verdict)          ← blocking; nothing is trustworthy before it
   │
   ├─ B (the four uncontrolled fixes)  ← makes 44bdcda's transport work evidence
   │     │
   │     └─ D (soak)                   ← needs a stable accept path to mean anything
   │
   └─ C (lane_collisions decision)     ← owner decision, then code, then green c05
                                          can proceed in parallel with B

E (benchmark)                        ← independent, optional, last
```

A single agent with SSH to the prepared box can run A, then B, then D
sequentially; D is a day of wall time but almost no attention. C needs the owner
before it starts.

## What "ready for deploy" means after this

With A, B, C and D green, the framework's own evidence would cover the accept
path under fault, the concurrency fixes that currently rest on argument, the
saturation signal, and long-run memory behaviour. Two properties remain
deliberate design choices rather than gaps, and belong in the operations
documentation rather than in this plan:

- **No panic recovery.** A handler that indexes out of bounds takes down the
  process — every lane, every in-flight request. ADR-020 ratifies running under
  a supervisor; that is a legitimate answer, but it must be prominent, not
  implied.
- **Per-connection memory retention is bounded by no setting.** Delegated to a
  cgroup, with the sizing rule `max_connections × largest response`.
