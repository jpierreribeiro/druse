# J3 — JSON decode memory amplification, measured

Date: 2026-07-28. Host: 4 vCPU KVM, 15 GB RAM.
Toolchain: the pinned `dev-2026-07-nightly:819fdc7`.

## What J3 claims

> A 4 MiB body of `[{},{},{},…]` is ~1.4M elements at 3 bytes each. Decoded into
> `[]T` for a large DTO, the fused decoder allocates `len × size_of(T)` in one
> shot — amplification of `size_of(T)/3`, easily hundreds of MB per request per
> lane. Separately, the disposable preflight tree costs roughly 10–20× the body
> in `json.Value` nodes … `max_body` bounds bytes, not this multiplier, and
> `Limits` has no field for it.

The backlog marks J3 unmeasured and proposes the method: RSS high-water while
POSTing 4 MiB of `{},` at a `[]BigDTO` endpoint.

## Method

Two routes, identical but for the bound type: `[]Small` (`size_of` 8) and
`[]Big` (`size_of` 288 — sixteen strings and four ints, the shape an ordinary
application writes). One POST each of a 4 MiB body, `[{},{},…]`, 1,398,101
empty objects, inside the 4 MiB `BODY_LIMIT`. Both are answered 200 with the
decoded element count, so the decode really happens.

RSS is sampled by a **watcher thread at 1 ms** for the duration of the request,
and the peak is reported.

**Sampling before and after the request is not a measurement of this.** The
first version of this probe did exactly that and reported a +52 MB delta for
`[]Big`, which reads as a refutation of J3. It is an artifact: the request arena
is reset when the request ends, so a peak that exists only during the decode is
gone before the "after" reading. The delta understates the high-water by more
than 11×. The backlog said *high-water* for this reason.

## Result

Identical to 0.1 MB across three runs.

| bound type | `size_of(T)` | RSS peak rise | amplification vs. the 4 MiB body |
|---|---|---|---|
| `[]Small` | 8 | **+211 MB** | **≈53×** |
| `[]Big` | 288 | **+588 MB** | **≈147×** |

## Verdict

**J3 is confirmed, and the decomposition matches the stated mechanism exactly.**

- The `[]Small` figure is the preflight tree alone — an 8-byte element type
  cannot account for 211 MB of element storage. So the disposable
  `json.Value` tree costs **≈53× the body**, above the "10–20×" the backlog
  estimated.
- `[]Big` adds `1,398,101 × 288 = 384 MB` of element storage on top. Predicted
  total 211 + 384 = 595 MB against 588 MB measured — the two halves are
  additive and the "allocates `len × size_of(T)` in one shot" claim holds.

**A single in-limit request transiently costs ~588 MB of RSS.** `max_body` is
doing its job — the body really is 4 MiB — and it is the wrong dimension: what
the peak scales with is element count times destination size, neither of which
`Limits` can express today. Concurrency multiplies it per lane.

## What this does NOT establish

- **Concurrency.** One request was measured. Whether N simultaneous requests
  multiply the peak cleanly, or contend earlier on the allocator, is untested.
- **A cgroup verdict.** The C-04 sizing rule is `max_connections × largest
  response`; this is a REQUEST-side multiplier that rule does not model, but
  what a given `MemoryMax` survives has not been tried.
- **The fix.** Bounding this means a new `Limits` field (element count, or a
  decoded-size ceiling), which is a public-API change under the Phase-1 freeze
  and needs owner sign-off. Nothing here chooses the shape.

## Reproduce

`/tmp/…/j3probe` in the session scratch, or rebuild it: two routes differing
only in bound type, a 4 MiB `[{},…]` body, and a 1 ms RSS sampler thread. The
sampler is the part that matters.
