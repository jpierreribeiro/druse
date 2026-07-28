# J4 — hash-flooding `json.Object`, measured

Date: 2026-07-28. Host: 4 vCPU KVM.
Toolchain: the pinned `dev-2026-07-nightly:819fdc7`.

## What J4 claims

> **J4 — Hash-flooding of `json.Object`. UNVERIFIED.** Every object body becomes
> an Odin `map[string]json.Value`. Whether that is floodable depends on the
> pinned runtime's map seeding. *Measure: time-to-parse for 100k colliding vs
> random 8-byte keys in one 4 MiB object. If quadratic, a key-count cap is the
> precedent-following fix.*

## The colliding half of that method cannot be built, and the reason is the answer

`map_seed_from_map_data` in `base/runtime/dynamic_map_internal.odin` derives the
map's hash seed by splitmix over the map's **data pointer** — a heap address.
Two consequences, and the second is the stronger one:

1. The seed is not a build-time constant, so a collision set cannot be computed
   offline and reused against every server.
2. **The seed changes whenever the map resizes**, because the data pointer
   changes. Inserting 100k keys crosses many growth thresholds, so a key set
   engineered to collide under the seed the map had at 1k entries stops
   colliding at 2k, and again at 4k.

An attacker would have to predict a specific heap address in a specific
process — and then the map would rehash away from it mid-insert. **The
hash-flooding mechanism J4 names is not available.**

## What is measurable, and was measured

Time-to-respond for one object of N distinct 8-character keys bound to a
`map[string]int` destination, so every key reaches the map and none is refused
as an unknown field. Loopback, `Connection: close`, warmed.

| keys | body | elapsed | µs/key |
|---|---|---|---|
| 10,000 | 127 KB | 40 ms | 3.97 |
| 25,000 | 317 KB | 180 ms | 7.21 |
| 50,000 | 635 KB | 305 ms | 6.11 |
| 100,000 | 1.27 MB | 654 ms | 6.54 |
| **322,000** | **4.09 MB (at `BODY_LIMIT`)** | **1.70 s** | **5.28** |

The 4 MiB row across three runs: 1.70 s, 1.99 s, 2.08 s.

## Verdict

**The quadratic hypothesis is not supported.** Per-key cost is flat within run
noise from 25k keys upward — roughly 5–7 µs/key with no systematic growth. Cost
is linear in key count, so the "if quadratic, add a key-count cap" branch of the
backlog's own instruction does not fire.

**A different concern is confirmed in its place, and it is not about hashing.**
One request, inside every limit the framework has, costs **~1.7–2.1 seconds**.
Handlers run synchronously on their lane under dedicated accept, so that is a
lane occupied for two seconds by a single client. With `max_handlers` defaulting
to the core count, a handful of concurrent requests of this shape saturate every
lane — no collisions, no malformed input, nothing `max_body` can see. The body
really is 4 MiB; it just contains 322,000 keys.

This is the same shape as J3 measured on the same day: `max_body` bounds bytes,
and bytes are not what the cost scales with. J3's multiplier is memory
(element count × destination size); J4's is CPU (key count × ~6 µs).

## What this does NOT establish

- **Concurrency.** One request at a time was measured. Whether N concurrent
  requests degrade linearly or worse is untested.
- **Where the time goes.** 6 µs/key is the end-to-end figure; no profile
  separates tokenising, map insertion, the unknown-key scan and the decode.
  A key-count cap and a faster decoder are different fixes and this does not
  choose between them.
- **The fix.** As with J3, a bound would be a new `Limits` field — a public-API
  change under the Phase-1 freeze needing owner sign-off.

## Correction to the backlog

J4 should stop being carried as "hash-flooding, unverified". The flooding
question is **settled and negative** on the pinned toolchain, for a structural
reason worth keeping written down: the seed is an address that moves on resize.
What should replace it is the measured entry above — a per-key CPU cost that
`max_body` does not bound.

---

## Addendum, same day: the bound, and where the boundary actually fell

Closed by the same field as J3, `Limits.max_json_nodes` (Phase-1 freeze
Amendment 38), because the two findings are one quantity seen twice. A
key-count cap — the backlog's proposal for J4 specifically — was rejected on
J3's evidence: that body has 1.4M values and **zero keys**, so a key cap would
not have seen it at all.

Same probe, same host. `keys` here counts object keys; the node budget sees
`2N + 1` for an N-key object, so the 100,000 default admits just under 50,000
keys:

| keys | nodes | unbounded (control) | with the default |
|---|---|---|---|
| 10,000 | 20,001 | 28.7 ms, 200 | **32.4 ms, 200** |
| 25,000 | 50,001 | 97.6 ms, 200 | **99.3 ms, 200** |
| 50,000 | 100,001 | 267.6 ms, 200 | **8.8 ms, 413** |
| 100,000 | 200,001 | 500.0 ms, 200 | **19.3 ms, 413** |
| 322,000 | 644,001 | 1.57 s, 200 | **50.4 ms, 413** |

**The worst case falls from 1.57 s of Handler-lane time to 50 ms**, and the
refusal cost is the single scan pass — it grows with body bytes, not with
structures, which is why the 4 MiB refusal is 50 ms rather than 8.8 ms.

**The boundary landed where it was documented, not where it was hoped.** 25,000
keys is 50,001 nodes and is served; 50,000 keys is 100,001 nodes and is refused
by one. That the transition is exactly one node wide is the evidence that the
count is exact rather than approximate — an estimate would have blurred it.

**Legitimate traffic is untouched, measured rather than assumed.** The 10,000-
and 25,000-key rows are within noise of the control (32.4 vs 28.7 ms, 99.3 vs
97.6 ms). The scan is not free, but it is not detectable at these sizes either.
