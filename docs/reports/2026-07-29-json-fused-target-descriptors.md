# Integrated fused-target JSON descriptors

Date: 2026-07-29

## Decision

Adopt the request-local fused-target descriptor.

This is not the standalone RTTI cache rejected on 2026-07-25. That experiment
cached repeated struct metadata during validation but still paid field
resolution in the later stdlib decode. The current fast path already decodes
from the strict parsed tree. Its descriptor is enabled only for types eligible
for that fused path and is shared by:

1. known-field shape validation;
2. unknown-field detection; and
3. destination writes.

Types that require the stdlib fallback do not allocate or build the descriptor.
The descriptor lives in the disposable preflight arena, introduces no global
state or synchronization, and preserves explicit-tag, ordinary-name and
flattened-`using _` precedence.

## Correctness evidence

`build/check_wp68_controls.sh` runs the public decoder corpus with the
descriptor both enabled and disabled. It also builds a private mutant that
zeros every resolved field offset and requires the decoder corpus to fail.
Existing WP67 cases cover tagged fields, shadowing and flattened fields, while
the allocation-failure and transport controls retain their prior taxonomy.

The private rollback is:

```text
-define:DRUSE_JSON_FUSED_TARGET_DESCRIPTORS=false
```

It is a maintainer A/B control, not application configuration.

## AWS A/B

Machine: AWS c5.2xlarge, eight vCPUs. The server was pinned to CPUs 0-3 and
`wrk` to CPUs 4-7. Each measured repetition used four generator threads,
100 connections and ten seconds after a five-second warm-up. Both binaries
were built from commit `cba117e` with the pinned Odin nightly; the control
changed only `DRUSE_JSON_FUSED_TARGET_DESCRIPTORS=false`.

First order (control, then candidate), ten repetitions:

| workload | control req/s | candidate req/s | throughput | control p99 | candidate p99 |
|---|---:|---:|---:|---:|---:|
| medium decode | 17,467.67 | 20,154.52 | +15.38% | 11.105 ms | 9.675 ms |
| medium round trip | 10,031.70 | 10,542.24 | +5.09% | 18.360 ms | 17.540 ms |

Reverse order (candidate, then control), five medium and ten small
repetitions:

| workload | control req/s | candidate req/s | throughput | control p99 | candidate p99 |
|---|---:|---:|---:|---:|---:|
| medium decode | 17,508.63 | 20,146.09 | +15.06% | 10.820 ms | 9.630 ms |
| medium round trip | 10,062.46 | 10,532.00 | +4.67% | 18.250 ms | 17.400 ms |
| small echo | 140,370.79 | 140,556.93 | +0.13% | 1.605 ms | 1.580 ms |

The decode-only gain clears the 10% adoption threshold in both orders. The
round-trip gain is smaller because response encoding is unchanged. Small echo
is noise-level and shows no short-path regression. Median p99 improved in every
row.

Raw `wrk` outputs, scripts, binary/source checksums and the exact Git bundle are
stored outside the repository under:

```text
PRIORIDADE/entrega/evidencias/2026-07-29-json-fused-target-aws/
```

## Remaining limit

This removes repeated reflective field-target work. It does not turn the
general tree parser into a typed monomorphized parser, and it does not improve
response serialization. Axum's Serde path therefore remains the useful ceiling
for a future one-pass typed decoder study.
