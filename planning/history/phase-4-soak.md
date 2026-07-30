# WP53 / WP54 — the soak, and what it did and did not measure

**Date: 2026-07-21.** Instrument: `experiments/13-soak/`.

## The run

400 rounds × 8 concurrent clients, each client reusing **one connection** for a
GET and a POST alternately — 800 requests in total, driven by a threaded Python
client rather than a `curl` loop.

| | |
|---|---|
| HTTP 200 | **400** |
| HTTP 201 | **400** |
| anything else | **0** |
| connections | 8, each carrying 100 requests |

**Every request was answered correctly.** That is the result, and it is a
narrower one than the plan asked for.

**The keep-alive path is what makes it worth having.** One connection per client
carrying a hundred requests exercises exactly the path WP45 repaired — before
that fix, every request would have needed its own connection, and this shape of
load would have failed on request two.

## What this did NOT measure, stated plainly

**No latency percentiles, and none will be reported from this harness.**
FINDING-A, re-verified at the Phase-3 freeze, puts this machine's noise floor at
**13,821 basis points — 138%**. A p99 from a run inside that band is a number
about the machine, not about the framework.

**RSS was not usefully captured.** The instrument reads `/proc/<pid>/status`
before and after, and on this run the process had already been terminated when
the second read happened — so `rss_end` is 0 and the reported growth is
meaningless. **It is recorded as a broken measurement rather than as a −2,432 KB
improvement**, which is what the arithmetic would otherwise have claimed.

**The soak is short.** 800 requests is a smoke test with a plural. A soak that
would surface a slow leak runs for hours, and the honest word for what ran here
is *load*, not *soak*.

## WP54 — the allocator audit is NOT delivered

The plan asked for a tracking allocator over the full serve path. It is not
here, and the reason is not effort:

**The serve path does not run under an allocator this process controls.** The
vendored server owns per-connection arenas and a per-thread temp allocator, and
`web.serve` hands it a `Config`, not an allocator. Installing a tracking
allocator over that path means either patching the vendored allocator plumbing —
**which is precisely the uncontained kind of patch WP44 hit and ADR-033 is
reopened over** — or measuring only the part Druse already owns, which WP27
and WP35 have measured twice.

**So the finding is the same one, arriving a third time:** what this project can
observe cheaply stops at the boundary of the vendored event loop. That is now
three independent packages saying it (WP44's drain, WP46's containment, and
this), and it belongs to ADR-033's decision rather than to a test.

**What IS known about allocation**, from instruments that do work: WP27's
allocation audit, WP35's arena policy and R-16 measurement, and the WP17 finding
of zero allocations through a five-middleware chain. None of those is
whole-system, and none is claimed to be.

## What a real WP53/WP54 needs, recorded so it is not re-derived

1. **A quiet machine, or a paired-run design.** Not a tighter number on this one.
2. **A load generator that is not the bottleneck.** The Python driver was
   already 20× faster than the `curl` loop it replaced; a real one would be
   another step.
3. **Hours, not seconds**, for anything that deserves the word soak.
4. **An allocator seam through the vendored server** — or the owned connection
   layer ADR-033 is deciding about, which would come with one by construction.
