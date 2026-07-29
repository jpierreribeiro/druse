# M9 — request-buffer retention, measured and attributed

Initial measurement: 2026-07-28. Attribution follow-up: 2026-07-29.
Toolchain: the pinned `dev-2026-07-nightly:819fdc7`.

## What M9 claims

> `clean_request_loop` does `free_all` on the connection's growing arena, which
> resets the offset but keeps reserved blocks; the scanner buffer only ever
> grows. One large exchange permanently grows that keep-alive connection —
> worst case `max_connections × largest exchange` — and `max_idle_time = 0`
> means idle connections are never reaped. Known and measured (F-C04-1),
> delegated to a cgroup.

## One half of the proposed mechanism did not survive reading the toolchain

`virtual.arena_free_all` on a `.Growing` arena frees every block **but the
first** — `core/mem/virtual/arena.odin:224`, with upstream's own comment saying
so. It retains one block, not "reserved blocks", so a large exchange whose
allocations spilled into later blocks gives those back.

The scanner half held before patch 41. `scanner_reset` did
`remove_range(&s.buf, 0, start)`, which moved `len` and never returned the
backing allocation, and the buffer is sized to the **body**:
`_body_length` sets `max_token_size = ilen`.

## Method

16 keep-alive connections, one POST each, then **left open and idle** — the
claim is about retention on an idle connection, so closing them would measure
nothing. RSS from `/proc/self/statm` while they are still open. The control is
the same connection count and request count with 64-byte bodies, so the only
variable is body size.

## Initial RSS result

| body per connection | retained per connection, before | after patch 41 |
|---|---|---|
| 64 B | 0.01 MB | 0.01 MB |
| 1 MiB | **2.02 MB** | **1.26 MB** |
| 3 MiB | **6.49 MB** | **3.50 MB** |

RSS was linear in body size, at roughly **2.1× the body** before the patch and
**1.17×** after.

That was enough to identify and repair the live scanner buffer, but not enough
to classify the post-patch remainder. RSS cannot distinguish an allocation
that is still owned by a connection from pages an allocator has freed but has
not returned to the kernel. Calling the remainder "one more allocation site"
was therefore an inference, not a measurement.

## Attribution follow-up: counting the connection allocator

The follow-up wraps the exact allocator captured as the backend
`Server.conn_allocator`. Four keep-alive connections first serve a small
request. They then send 3 MiB bodies to four handlers that block on a semaphore,
so all scanner buffers are provably alive at the sample. The handlers are
released, all four responses are read, and the same allocator is sampled after
`scanner_reset`.

| sample | current live bytes | body-sized live allocations |
|---|---:|---:|
| warmed baseline | 229,418 | 0 |
| four bodies blocked in handlers | 16,363,562 | 4 / 16,138,240 bytes |
| responses completed | 229,418 | 0 |

The live total returns **exactly** to its warmed baseline. Between the baseline
and final sample the allocator reports 32,272,696 bytes allocated and exactly
32,272,696 bytes freed. The four large live entries during the blocked phase
are all the scanner growth at `scanner.odin:343`.

Temporary internal instrumentation measured the connection arena at the same
time. For each 3 MiB request it had one 1 MiB-reserved block, only **4,040 bytes
committed**, and 1,002 bytes used before cleanup; after `free_all`, the same
block had 4,040 bytes committed and zero used. The arena is not the body-sized
remainder.

The corresponding RSS moved 9.75 → 26.75 → 11.55 MiB. The final RSS not being
byte-for-byte identical to the first sample is allocator/process high-water
and measurement noise; the connection allocator proves there is no live
body-sized owner behind it.

## Negative control

The control removes `delete(s.buf)` from patch 41 in a temporary mutation. The
same final sample then retains four allocations totalling **16,138,240 bytes**,
the test fails both after-response assertions, and Odin's leak report locates
all four at `scanner.odin:343`. The control therefore proves the counter sees
the defect that the production branch removes.

This is now permanent as `tests/m9-attribution` and
`build/check_m9_controls.sh`, both run by the full gate.

## Revised verdict

**M9 is closed.** Patch 41 fixes a real live per-connection retention defect:
before it, the scanner kept its largest body buffer for the lifetime of an idle
keep-alive connection. After it, no body-sized allocation remains live on the
connection allocator, and the connection arena commits only a few kilobytes for
this path.

The original post-patch estimate of roughly **4.8 GB** at shipped defaults is
withdrawn. It multiplied an RSS remainder as though it were a second live
per-connection allocation; the counting allocator shows that allocation does
not exist. Large concurrent requests still have a transient memory cost and
remain bounded by the ingress and connection/admission limits, but that is peak
working memory, not idle retention.

## The risk the patch creates, and the control for it

`s.end` is the live prefix of bytes that have already arrived, which on a
pipelined connection is the **next request**. Discarding the buffer with that
present would drop a request the client has already sent and will never resend.
The patch guards on `s.end == 0`, and
`wp9_a_shrink_after_a_large_body_does_not_drop_a_pipelined_request` sends
exactly that shape: a 1 MiB body with a second request in the same write.

With the guard removed the test does not fail an assertion — **it hangs**, and
had to be killed. That is the failure mode in its own right: a dropped
pipelined request wedges the connection and the shutdown behind it, so the
symptom is a stuck server rather than an error.
