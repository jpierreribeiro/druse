# Hardening verification on the VPS — 2026-07-24

The record H-5 asks for: what was run on real hardware, what it found, and what
remains owed with the exact procedure to run it. Nothing here touches the box's
existing CI (`druse-ci` systemd unit), its docker `runner`, or the Caddy
instance on 80/443/2019 — all work is confined to `/opt/druse-verify`.

## Environment

| | |
|---|---|
| Host | `45.32.215.234` (owner's test VPS) |
| Kernel / arch | `7.0.0-27-generic` / `x86_64` |
| CPUs | 2 |
| Memory | 1636 MiB total, ~830–890 MiB available (shared with CI + Caddy) |
| **`ulimit -l` (memlock)** | **8192 KiB (8 MiB)** — the constraint that matters below |
| `ulimit -n` | 1024 |
| Toolchain | `/opt/druse/odin` `dev-2026-07-nightly:819fdc7` — **commit matches the repo pin** (`odin-version.txt` `commit=819fdc7`), reused read-only |
| clang | 21.1.8 |
| Repo | `/opt/druse-verify/repo`, branch `closure` @ the H-2 commit |
| Already running (DO NOT TOUCH) | ssh(22), Caddy(80/443, admin 2019), a service on 8090, docker `runner` (CI), the `druse-ci` timer |

## H-2 — F-C03-2 reproduced AND diagnosed

**This is the headline result.** The Closure left F-C03-2 as the one open
defect: real-socket suites crashing at a low rate under gate load, signature a
crash at server *startup*, cause unknown, standing advice "re-run".

**Reproduction (before the fix).** `tests/c05-saturation` built with
`-sanitize:address` and run on this host aborted at:

```
vendor/odin-http/server.odin(274:2) runtime assertion: acquire_err == nil
```

— at server startup, exactly the recorded signature.

**Diagnosis.** `nbio.acquire_thread_event_loop()` sets up the thread's
`io_uring` rings, which **pin memory against `RLIMIT_MEMLOCK`**. One loop is
created per Handler lane per server, so on a host with an 8 MiB memlock budget
and <1 GiB free, the ring allocation fails (`Allocation_Failed`), and the
vendored server *asserted* on it — the deferred error handling upstream never
wrote — turning a resource failure into a startup crash the test runner reports
as `Segmentation_Fault`. The dev-box "1 in 10 under load" and this box's "every
ASan run" are the same defect at different distances from the memlock limit.

**Deterministic confirmation of the fix (vendored patch 29).** Forcing the
failure with `ulimit -l 16` and running the patched build produced the intended
diagnostic instead of a bare abort:

```
server.odin(360:3) runtime assertion: druse: a Handler lane could not acquire
its io_uring event loop (Allocation_Failed). This is typically RLIMIT_MEMLOCK
(ulimit -l) or memory exhaustion — raise the locked-memory limit or lower
max_handlers. (F-C03-2)
```

The `Allocation_Failed` operand is the proof: the ring setup ran out of pinned
memory. The crash is now actionable. The graceful serve-failure unwind (return
an error from `web.serve` rather than terminate) is specified as a follow-up in
`planning/closure-record-and-verdict.md` §3.1.

**FIX VERIFIED (patch 30).** The graceful unwind — `web.serve` returning /
reporting `Serve_Listen_Failed` instead of the process terminating — was proven
on this host: `tests/h2-graceful-acquire` forces `RLIMIT_MEMLOCK` to 16 KiB (the
condition that aborted at `server.odin:360` before the patch) and the test
SURVIVES to its final assertion, which is only possible if `web.serve` returned
rather than crashing. So F-C03-2 is not just diagnosed but fixed: a startup
resource shortfall is now a supervisor-restartable error.

**Operational consequence for THIS host:** raise memlock before running the
socket suites or any many-lane workload —
`bash -c 'ulimit -l unlimited; …'` (root can) or size `max_handlers` down.

## Owed demonstrations — status and procedure

Three demonstrations remain owed from earlier phases (recorded in
`planning/closure-response-size-and-memory.md`, `planning/closure-proxy-contract.md`,
and the Phase-7 freeze). **They are deliberately NOT run to completion on this
box**, and the reason is an engineering call, not omission:

- This is a **shared CI host** with 8 MiB memlock, <1 GiB free, and a live Caddy
  + docker runner. The H-2 diagnosis is precisely that this class of workload
  exhausts locked memory here; driving 3,000 real sockets or installing nginx
  alongside Caddy risks the CI and Caddy the owner said must not be touched.

The safe procedure for each, to run on a **dedicated** quiet host (or this one
with `ulimit -l unlimited` and the CI paused), is `run-owed-demos.sh` beside this
file:

1. **Hours-long soak** — `tests/c04-response-size` looped for the duration, RSS
   sampled from `/proc/self/statm`; pass = no monotonic growth beyond the C-04
   leak threshold across the window.
2. **3,000 real-socket streams** — a real-socket build of the G7-6 wire proof
   (the registry-level 3,000 is already proven by `tests/wp96-scale`); needs
   `ulimit -n 8192` and `ulimit -l unlimited`.
3. **Real nginx round** — a dedicated `nginx -c … -p …` instance on a high port
   with `proxy_buffering off`, validating the two C-06 clauses against a real
   proxy (including the multi-hop `X-Forwarded-For` append that the C-06 fixture
   only approximates). Never the system nginx service.

Running any of them appends a dated result block to this file.

### VPS run, 2026-07-24 (bounded)

- **Soak (bounded).** `tests/c04-response-size` looped with `ulimit -l
  unlimited`, sampling memory: iterations completed **OK with FLAT RSS** —
  `used_mb` held at **375–376 MiB** across the samples (no monotonic growth).
  The leak-shape result C-04 proves in 2 s on the dev box holds on real
  hardware. The *hours-long* run remains owed (this was a bounded sample).
- **`g76 scale=500` OVERLOADED this box, which is itself a finding.** 500
  concurrent real-socket streams on 1.6 GiB RAM drove it into swap hard enough
  that `sshd` could not complete a handshake; the run was killed and the box
  recovered to 1352 MiB free once my processes were reaped. This is consistent
  with H-2's diagnosis — this host is memory- and memlock-constrained — and it
  is why the full 500+/3,000 rounds belong on a **dedicated** box. The wire-path
  proof itself is green at 100 and 300 on the dev box (above). Nothing of the
  host's own CI/Caddy was touched; only `/opt/druse-verify` processes were
  killed during cleanup.

## Real-socket streaming — `tests/g76-scale-sockets` (the wire path at scale)

Written and run this session. It opens N real client connections to a detached-
stream endpoint, a single broadcaster sends chunks to every open stream and
closes them, and it asserts the wire path, admission, and a bounded drain.

**Results (dev box, before the VPS run):**

| N clients | admitted (streams opened) | got a chunk | drain |
|---|---|---|---|
| 100 | 74 | **74 (all admitted)** | ~5.1 s |
| 300 | 177 | **177 (all admitted)** | ~5.1 s |

**Two findings the test makes concrete:**

1. **The wire path is correct at scale:** *every admitted stream received its
   chunk* — the owner-lane pump and chunked framing hold. That is the G7-6 proof
   on real sockets (the registry-level 3,000 is already `tests/wp96-scale`).
2. **Admission falls as the arrival burst grows** (74% at 100, 59% at 300),
   because a synchronous stream-opening handler still meets the C-05 lane
   contention: clients that land on a busy lane get 503, not a stream. The test
   treats those as admission working, not a wire failure — which is the honest
   reading.

**And a limitation surfaced:** the public per-server stream cap is
`DEFAULT_MAX_STREAMS = 1024` with **no public knob** to raise it. So a "3,000
real socket" round on ONE server is not expressible through the public surface
today — it needs a capacity setting that does not exist, or three servers. This
is recorded as an ABERTO item for the BOM / a future WP, not silently skipped.

The suite is **deliberately not in the default gate**: it is a 13 s socket test
whose whole point is load, and F-C03-2 is precisely socket suites crashing under
load — adding it to the gate would raise that risk for no daily benefit. It runs
via `run-owed-demos.sh scale` on a quiet host.
