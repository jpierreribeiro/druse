# R3-WP10 Stage 1 — the cost of N worker processes

Lanes per worker: **4**. Derived from `raw/per-worker.txt`; this page
groups those numbers and says what they mean. It replaces neither.

## Per worker

| N | workers sampled | FDs | threads | io_uring rings | ring bytes | VmLck KiB | VmRSS KiB |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 14 | 5 | 5 | 1044480 | 0 | 4456 |
| 2 | 2 | 14 | 5 | 5 | 1044480 | 0 | 4524 |
| 4 | 4 | 14 | 5 | 5 | 1044480 | 0 | 4492 |

## W1 — are the per-worker costs constant in N?

**PASS.** FDs, threads and io_uring rings per worker do not vary with N.
Each worker pays the same price; nothing is shared and nothing is coupled.

## W2/W3 — the aggregate, against each limit AND its own kind

The two limits are different KINDS of thing and adding them together is
the defect this table exists to prevent.

| N | aggregate FDs | aggregate ring bytes | aggregate RSS KiB | `LimitNOFILE` (per process) | `LimitMEMLOCK` (per process) | `MemoryMax` (cgroup, aggregate) |
|---|---|---|---|---|---|---|
| 1 | 14 | 1044480 | 4456 | ok | ok | 1024 MiB per worker |
| 2 | 28 | 2088960 | 9048 | ok | ok | 512 MiB per worker |
| 4 | 56 | 4177920 | 17968 | ok | ok | 256 MiB per worker |

### Reading that table

- **`LimitNOFILE` and `LimitMEMLOCK` are RLIMITs — PER PROCESS.** Each worker
  gets its own 2048 descriptors and its own 64 MiB of
  locked memory, so neither configured number has to grow with N. They are
  checked against the **largest single worker**, never against the sum.
- **`MemoryMax` is the cgroup's — AGGREGATE.** The same 1024 MiB is
  now shared by N workers. That is the number that actually changes meaning,
  and it changes silently: nothing in the unit says 'divided by N'.
- The host still has to physically hold the aggregate. A per-process limit
  that every process satisfies can still exhaust the machine.

### VmLck is 0, and that is the trap, not an error

Every worker maps io_uring rings and every worker reports `VmLck: 0`. The
kernel charges io_uring ring memory against RLIMIT_MEMLOCK **without**
reporting it under `VmLck`, so an operator watching `VmLck` to predict a
memlock exhaustion sees a flat zero right up to the allocation that fails.
That failure mode is already reproduced in this repository (F-C03-2, patch
30). The number to watch is the ring-bytes column, and nothing in /proc
hands it to you — it has to be summed from the mappings.
