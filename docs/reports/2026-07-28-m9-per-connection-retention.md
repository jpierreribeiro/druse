# M9 — per-connection retention, measured

Date: 2026-07-28. Host: 4 vCPU KVM, 15 GB RAM.
Toolchain: the pinned `dev-2026-07-nightly:819fdc7`.

## What M9 claims

> `clean_request_loop` does `free_all` on the connection's growing arena, which
> resets the offset but keeps reserved blocks; the scanner buffer only ever
> grows. One large exchange permanently grows that keep-alive connection —
> worst case `max_connections × largest exchange` — and `max_idle_time = 0`
> means idle connections are never reaped. Known and measured (F-C04-1),
> delegated to a cgroup.

## One half of the mechanism does not survive reading the toolchain

`virtual.arena_free_all` on a `.Growing` arena frees every block **but the
first** — `core/mem/virtual/arena.odin:224`, with upstream's own comment saying
so. It retains one block, not "reserved blocks", so a large exchange whose
allocations spilled into later blocks gives those back.

The scanner half holds. `scanner_reset` does `remove_range(&s.buf, 0, start)`,
which moves `len` and never the backing allocation, and the buffer is sized to
the **body**: `_body_length` sets `max_token_size = ilen`. It also grows by
**doubling**, so a 3 MiB body climbs 1 → 2 → 4 MiB and the ladder below the
final buffer stays resident in the allocator.

## Method

16 keep-alive connections, one POST each, then **left open and idle** — the
claim is about retention on an idle connection, so closing them would measure
nothing. RSS from `/proc/self/statm` while they are still open. The control is
the same connection count and request count with 64-byte bodies, so the only
variable is body size.

## Result

| body per connection | retained per connection, before | after patch 41 |
|---|---|---|
| 64 B | 0.01 MB | 0.01 MB |
| 1 MiB | **2.02 MB** | **1.26 MB** |
| 3 MiB | **6.49 MB** | **3.50 MB** |

Linear in body size, at roughly **2.1× the body** before the patch and **1.17×**
after.

## Verdict

**Confirmed, and the arithmetic is worse than "delegated to a cgroup" implies.**
At the shipped defaults — `max_connections` 1024, `max_body` 4 MiB — the
pre-patch worst case is `1024 × 2.1 × 4 MiB ≈ 8.6 GB` of idle retention. That
is not a budget a cgroup absorbs; it is one it kills the process over.

Vendor patch 41 returns the read buffer between requests once it exceeds
`RETAINED_BUF_MAX` (256 KiB), which is far above the request-line and header
ceilings (8000 each) so ordinary traffic never reaches it and never pays a
reallocation. **It removes 46% of the retention** and leaves the worst case at
about 4.8 GB.

## What this does NOT establish, stated rather than left implicit

**The remaining ~1.17× is not attributed.** It is not the scanner buffer — that
is now returned — and the arena keeps only its first block. It is one more
allocation site of roughly body size, and this report does not say which. M9 is
therefore **half closed**: the mechanism named in the finding is fixed and
measured, and a second mechanism of comparable size is now visible and
unexplained.

The honest next step is a counting allocator on the connection's allocator,
not another guess.

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
